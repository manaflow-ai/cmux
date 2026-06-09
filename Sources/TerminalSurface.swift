import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers

final class TerminalSurface: Identifiable, ObservableObject {
    final class SearchState: ObservableObject {
        @Published var needle: String
        @Published var selected: UInt?
        @Published var total: UInt?

        init(needle: String = "") {
            self.needle = needle
            self.selected = nil
            self.total = nil
        }
    }

    private struct PendingKeyEvent {
        let keycode: UInt32
        let mods: ghostty_input_mods_e
        let label: String

        var queuedByteCost: Int {
            max(label.utf8.count, 1)
        }
    }

    private enum PendingSocketInput {
        case pasteText(Data)
        case inputText(Data)
        /// Bytes that must be processed as terminal output, not user input.
        case processOutput(Data)
        case key(PendingKeyEvent)

        var estimatedBytes: Int {
            switch self {
            case .pasteText(let data), .inputText(let data), .processOutput(let data):
                return data.count
            case .key(let event):
                return event.queuedByteCost
            }
        }
    }

    private enum ParsedSocketInput {
        case rawBytes(Data)
        /// A complete terminal string control sequence such as OSC, DCS, PM, or APC.
        case terminalBytes(Data)
        case key(PendingKeyEvent)
    }

    private static let committedTextInputChunkByteLimit = 96

    enum NamedKeySendResult: Equatable {
        case sent
        case queued
        case unknownKey
        case inputQueueFull
        case surfaceUnavailable
        case processExited

        /// Whether the named key was delivered to the surface or queued for an
        /// imminently-started surface. `false` means the key never reached the PTY.
        var accepted: Bool {
            switch self {
            case .sent, .queued:
                return true
            case .unknownKey, .inputQueueFull, .surfaceUnavailable, .processExited:
                return false
            }
        }
    }

    enum InputSendResult: Equatable {
        case sent
        case queued
        case inputQueueFull
        case surfaceUnavailable
        case processExited

        var accepted: Bool {
            switch self {
            case .sent, .queued:
                return true
            case .inputQueueFull, .surfaceUnavailable, .processExited:
                return false
            }
        }
    }

    private(set) var surface: ghostty_surface_t?
    private weak var attachedView: GhosttyNSView?

    /// Whether the runtime Ghostty surface exists and has not begun teardown.
    ///
    /// Use this as a quick availability check. Before passing `surface` to
    /// Ghostty C APIs that dereference the pointer (e.g.
    /// `ghostty_surface_inherited_config`, `ghostty_surface_quicklook_font`),
    /// call `liveSurfaceForGhosttyAccess(reason:)` so stale freed pointers are
    /// rejected and quarantined.
    var hasLiveSurface: Bool { surface != nil && portalLifecycleState == .live }

    /// Whether the terminal surface view is currently attached to a window.
    ///
    /// Use the hosted view rather than the inner surface view, since the surface can be
    /// temporarily unattached (surface not yet created / reparenting) even while the panel
    /// is already in the window.
    var uiWindow: NSWindow? {
        guard let window = hostedView.window else { return nil }
        if let headlessStartupWindow, window === headlessStartupWindow {
            return nil
        }
        return window
    }

    var isViewInWindow: Bool { uiWindow != nil }

    func isHeadlessStartupWindow(_ window: NSWindow?) -> Bool {
        guard let window, let headlessStartupWindow else { return false }
        return window === headlessStartupWindow
    }
    let id: UUID
    private(set) var tabId: UUID
    /// Port ordinal for CMUX_PORT range assignment. Captured at construction so
    /// every runtime startup path uses the same immutable workspace port range.
    private let portOrdinal: Int
    /// Snapshotted once per app session so all workspaces use consistent values
    private static let sessionPortBase: Int = {
        let val = UserDefaults.standard.integer(forKey: AutomationSettings.portBaseKey)
        return val > 0 ? val : AutomationSettings.defaultPortBase
    }()
    private static let sessionPortRangeSize: Int = {
        let val = UserDefaults.standard.integer(forKey: AutomationSettings.portRangeKey)
        return val > 0 ? val : AutomationSettings.defaultPortRange
    }()
    private let surfaceContext: ghostty_surface_context_e
    private let configTemplate: CmuxSurfaceConfigTemplate?
    private let workingDirectory: String?
    let initialCommand: String?
    let tmuxStartCommand: String?
    let initialInput: String?
    private var nextRuntimeInitialInput: String?
    private let initialEnvironmentOverrides: [String: String]
    var requestedWorkingDirectory: String? { workingDirectory }
    let focusPlacement: TerminalSurfaceFocusPlacement
    private var additionalEnvironment: [String: String]
    var respawnInitialEnvironmentOverrides: [String: String] {
        initialEnvironmentOverrides
    }
    var respawnAdditionalEnvironment: [String: String] {
        var environment = additionalEnvironment
        environment.removeValue(forKey: SessionScrollbackReplayStore.environmentKey)
        return environment
    }
    let hostedView: GhosttySurfaceScrollView
    private let surfaceView: GhosttyNSView
    private var lastPixelWidth: UInt32 = 0
    private var lastPixelHeight: UInt32 = 0
    private var lastUncappedPixelWidth: UInt32 = 0
    private var lastUncappedPixelHeight: UInt32 = 0
    private var lastXScale: CGFloat = 0
    private var lastYScale: CGFloat = 0
    private var mobileViewportCellLimit: (columns: Int, rows: Int)?
    private let debugMetadataLock = NSLock()
    private let createdAt: Date = Date()
    private var runtimeSurfaceCreatedAt: Date?
    private var teardownRequestedAt: Date?
    private var teardownRequestReason: String?
    // Main-thread only. Public socket send entrypoints are MainActor-isolated
    // before reading `surface` or mutating this pending queue.
    private var pendingSocketInputQueue: [PendingSocketInput] = []
    private var pendingSocketInputBytes: Int = 0
    private let maxPendingSocketInputBytes = 1_048_576
    private var backgroundSurfaceStartQueued = false
    private var runtimeSurfaceSuspendedForAgentHibernation = false
    private var headlessStartupWindow: NSWindow?
    private var surfaceCallbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
    private var claudeCommandShim: ClaudeCommandShim?
    private var claudeCommandShimInstallTask: Task<ClaudeCommandShim?, Never>?
    private var claudeCommandShimInstallCompleted = false
    /// Heap-allocated userdata for the libghostty PTY tee callback (cmux
    /// fork extension). Installed in `createSurface` after
    /// `ghostty_surface_new` succeeds; released alongside
    /// `surfaceCallbackContext` whenever we tear down or rebuild the
    /// surface. The Mac sync server reads the tee'd bytes to broadcast
    /// raw PTY output to paired iPhones (`MobileTerminalByteTee`).
    private var mobileByteTeeContext: Unmanaged<MobileTerminalByteTeeUserdata>?
    /// The desired focus state for the Ghostty C surface. May be set before the
    /// C surface exists (e.g. during layout restoration); `createSurface`
    /// reapplies this value once the runtime surface exists, then keeps using it
    /// as a dedup guard to avoid redundant `ghostty_surface_set_focus` calls
    /// (prevents prompt redraws with P10k).
    ///
    /// Start unfocused and only opt into focus when the workspace/AppKit focus
    /// path explicitly requests it so background panes do not keep a focused
    /// state unless the workspace focus path requests it.
    private var desiredFocusState: Bool = false
    private(set) var clipboardReadGeneration = 0
#if DEBUG
    private var needsConfirmCloseOverrideForTesting: Bool?
    private var runtimeSurfaceFreedOutOfBandForTesting = false
    private var runtimeSurfaceCreateAttemptCountForTesting = 0
    private let debugForceRefreshCountLock = NSLock()
    private var debugForceRefreshCountValue = 0
    @MainActor
    static var runtimeSurfaceFreeOverrideForTesting: (@Sendable (ghostty_surface_t) -> Void)?
#endif
    private enum PortalLifecycleState: String {
        case live
        case closing
        case closed
    }
    private struct PortalHostLease {
        let hostId: ObjectIdentifier
        let paneId: UUID
        let instanceSerial: UInt64
        let inWindow: Bool
        let area: CGFloat
    }
    private var portalLifecycleState: PortalLifecycleState = .live
    private var portalLifecycleGeneration: UInt64 = 1
    private var activePortalHostLease: PortalHostLease?
    @Published var searchState: SearchState? = nil {
	        didSet {
	            if let searchState {
	                hostedView.cancelFocusRequest()
#if DEBUG
                cmuxDebugLog("find.searchState created tab=\(tabId.uuidString.prefix(5)) surface=\(id.uuidString.prefix(5))")
#endif
                searchNeedleCancellable = searchState.$needle
                    .removeDuplicates()
                    .map { needle -> AnyPublisher<String, Never> in
                        if needle.isEmpty || needle.count >= 3 {
                            return Just(needle).eraseToAnyPublisher()
                        }

                        return Just(needle)
                            .delay(for: .milliseconds(300), scheduler: DispatchQueue.main)
                            .eraseToAnyPublisher()
                    }
                    .switchToLatest()
                    .sink { [weak self] needle in
#if DEBUG
                        cmuxDebugLog("find.needle updated tab=\(self?.tabId.uuidString.prefix(5) ?? "?") surface=\(self?.id.uuidString.prefix(5) ?? "?") chars=\(needle.count)")
#endif
                        _ = self?.performBindingAction("search:\(needle)")
                    }
            } else if let oldValue {
                lastSearchNeedle = oldValue.needle
                searchNeedleCancellable = nil
#if DEBUG
                cmuxDebugLog("find.searchState cleared tab=\(tabId.uuidString.prefix(5)) surface=\(id.uuidString.prefix(5))")
#endif
                _ = performBindingAction("end_search")
            }
        }
    }
    @Published private(set) var keyboardCopyModeActive: Bool = false
    private(set) var lastSearchNeedle = ""
    private var searchNeedleCancellable: AnyCancellable?
    var currentKeyStateIndicatorText: String? { surfaceView.currentKeyStateIndicatorText }

    private static func cmuxContextEnvironment(
        workspaceId: UUID,
        surfaceId: UUID,
        socketPath: String
    ) -> CmuxContextEnvironment {
        CmuxContextEnvironment(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            socketPath: socketPath
        )
    }

    /// Pre-spawn lookup for managed context keys and explicit startup overrides.
    /// Full runtime-only values such as bundle, port, PATH, and shell-integration
    /// entries are assembled when a Ghostty surface is created.
    @MainActor
    func startupEnvironmentValue(_ key: String) -> String? {
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        var environment: [String: String] = [:]
        var protectedKeys: Set<String> = []
        Self.applyManagedCmuxContextEnvironment(
            Self.cmuxContextEnvironment(
                workspaceId: tabId,
                surfaceId: id,
                socketPath: socketPath
            ),
            to: &environment,
            protectedKeys: &protectedKeys
        )
        return Self.mergedStartupEnvironment(
            base: environment,
            protectedKeys: protectedKeys,
            additionalEnvironment: additionalEnvironment,
            initialEnvironmentOverrides: initialEnvironmentOverrides
        )[key]
    }

    init(
        id: UUID = UUID(),
        tabId: UUID,
        context: ghostty_surface_context_e,
        configTemplate: CmuxSurfaceConfigTemplate?,
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        initialEnvironmentOverrides: [String: String] = [:],
        additionalEnvironment: [String: String] = [:],
        focusPlacement: TerminalSurfaceFocusPlacement = .workspace
    ) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif

        self.id = id
        self.tabId = tabId
        self.surfaceContext = context
        self.configTemplate = configTemplate
        self.workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.portOrdinal = portOrdinal
        let trimmedCommand = initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialCommand = (trimmedCommand?.isEmpty == false) ? trimmedCommand : nil
        let trimmedTmuxStartCommand = tmuxStartCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tmuxStartCommand = (trimmedTmuxStartCommand?.isEmpty == false) ? trimmedTmuxStartCommand : nil
        let trimmedInput = initialInput?.isEmpty == false ? initialInput : nil
        self.initialInput = trimmedInput
        self.initialEnvironmentOverrides = Self.mergedNormalizedEnvironment(base: [:], overrides: initialEnvironmentOverrides)
        self.additionalEnvironment = Self.mergedNormalizedEnvironment(base: [:], overrides: additionalEnvironment)
        self.focusPlacement = focusPlacement
        // Match Ghostty's own SurfaceView: ensure a non-zero initial frame so the backing layer
        // has non-zero bounds and the renderer can initialize without presenting a blank/stretched
        // intermediate frame on the first real resize.
        let view = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.surfaceView = view
        self.hostedView = GhosttySurfaceScrollView(surfaceView: view)
        TerminalSurfaceRegistry.shared.register(self)
        self.hostedView.attachSurface(self)

        let inheritedCommand = configTemplate?.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        let inheritedInput = configTemplate?.initialInput
        let hasStartupWork = self.initialCommand != nil
            || self.tmuxStartCommand != nil
            || trimmedInput != nil
            || inheritedCommand?.isEmpty == false
            || inheritedInput?.isEmpty == false

        // Surfaces with startup work must spawn before the user focuses their workspace.
        // Ghostty's embedded surface creation still expects a view with a window, so use
        // a hidden bootstrap window until the real portal host is ready.
        if hasStartupWork {
            MainActor.assumeIsolated {
                scheduleHeadlessRuntimeStartIfNeeded(reason: "startup")
            }
        }
    }

    func debugWaitAfterCommand() -> Bool {
        configTemplate?.waitAfterCommand ?? false
    }

    var launchContext: ghostty_surface_context_e {
        surfaceContext
    }

    func updateWorkspaceId(_ newTabId: UUID) {
        tabId = newTabId
        attachedView?.tabId = newTabId
        surfaceView.tabId = newTabId
    }

    @MainActor
    private func scheduleHeadlessRuntimeStartIfNeeded(reason: String) {
        startRuntimeUsingHeadlessWindowIfNeeded(reason: reason)
    }

    @MainActor
    private func startRuntimeUsingHeadlessWindowIfNeeded(reason: String) {
        guard allowsRuntimeSurfaceCreation() else { return }
        guard surface == nil else { return }
        ensureHeadlessStartupWindowIfNeeded(reason: reason)
        hostedView.attachSurface(self)
    }

    @MainActor
    private func ensureHeadlessStartupWindowIfNeeded(reason: String) {
        guard headlessStartupWindow == nil else { return }
        guard hostedView.window == nil else { return }

        let width = max(surfaceView.bounds.width, CGFloat(800))
        let height = max(surfaceView.bounds.height, CGFloat(600))
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.isExcludedFromWindowsMenu = true

        let contentView = NSView(frame: frame)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        window.contentView = contentView
        headlessStartupWindow = window
        hostedView.setVisibleInUI(false)
        hostedView.setActive(false)

#if DEBUG
        cmuxDebugLog(
            "surface.headless_window.create surface=\(id.uuidString.prefix(8)) " +
            "reason=\(reason) window=\(ObjectIdentifier(window))"
        )
#endif
    }

    @MainActor
    private func releaseHeadlessStartupWindowIfNeeded(for view: GhosttyNSView) {
        guard let window = headlessStartupWindow else { return }
        guard let currentWindow = view.window, currentWindow !== window else { return }
        headlessStartupWindow = nil
        window.contentView = nil
        window.close()
#if DEBUG
        cmuxDebugLog(
            "surface.headless_window.release surface=\(id.uuidString.prefix(8)) " +
            "realWindow=\(ObjectIdentifier(currentWindow))"
        )
#endif
    }

    private func closeHeadlessStartupWindowIfNeeded() {
        let startupWindow = headlessStartupWindow
        headlessStartupWindow = nil
        guard let startupWindow else { return }

        let closeStartupWindow = {
            startupWindow.contentView = nil
            startupWindow.close()
        }
        if Thread.isMainThread {
            closeStartupWindow()
        } else {
            DispatchQueue.main.async(execute: closeStartupWindow)
        }
    }

    @MainActor
    func reconcileAttachedWindowIfNeeded(for view: GhosttyNSView) {
        guard attachedView === view else { return }
        releaseHeadlessStartupWindowIfNeeded(for: view)
        guard let screen = view.window?.screen ?? NSScreen.main,
              let displayID = screen.displayID,
              displayID != 0 else { return }
        guard let s = liveSurfaceForGhosttyAccess(reason: "reconcileAttachedWindow") else { return }
        ghostty_surface_set_display_id(s, displayID)
    }

    private static func mergedNormalizedEnvironment(
        base: [String: String],
        overrides: [String: String]
    ) -> [String: String] {
        var merged: [String: String] = [:]
        merged.reserveCapacity(base.count + overrides.count)
        for (rawKey, value) in base {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            merged[key] = value
        }
        for (rawKey, value) in overrides {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            merged[key] = value
        }
        return merged
    }

    func isAttached(to view: GhosttyNSView) -> Bool {
        attachedView === view && surface != nil
    }

    func portalBindingGeneration() -> UInt64 {
        portalLifecycleGeneration
    }

    func portalBindingStateLabel() -> String {
        portalLifecycleState.rawValue
    }

    private func withDebugMetadataLock<T>(_ body: () -> T) -> T {
        debugMetadataLock.lock()
        defer { debugMetadataLock.unlock() }
        return body()
    }

    func debugCreatedAt() -> Date {
        withDebugMetadataLock { createdAt }
    }

    func debugRuntimeSurfaceCreatedAt() -> Date? {
        withDebugMetadataLock { runtimeSurfaceCreatedAt }
    }

    func debugTeardownRequest() -> (requestedAt: Date?, reason: String?) {
        withDebugMetadataLock { (teardownRequestedAt, teardownRequestReason) }
    }

    func debugLastKnownWorkspaceId() -> UUID {
        tabId
    }

    func debugSurfaceContextLabel() -> String {
        cmuxSurfaceContextName(surfaceContext)
    }

    func debugPortalHostLease() -> (hostId: String?, paneId: UUID?, inWindow: Bool?, area: CGFloat?) {
        guard let activePortalHostLease else {
            return (nil, nil, nil, nil)
        }
        return (
            hostId: String(describing: activePortalHostLease.hostId),
            paneId: activePortalHostLease.paneId,
            inWindow: activePortalHostLease.inWindow,
            area: activePortalHostLease.area
        )
    }

    func canAcceptPortalBinding(expectedSurfaceId: UUID?, expectedGeneration: UInt64?) -> Bool {
        guard portalLifecycleState == .live else { return false }
        if let expectedSurfaceId, expectedSurfaceId != id {
            return false
        }
        if let expectedGeneration, expectedGeneration != portalLifecycleGeneration {
            return false
        }
        return true
    }

    @MainActor
    func liveSurfaceForGhosttyAccess(reason: String) -> ghostty_surface_t? {
        guard hasLiveSurface, let surface else { return nil }
        let registry = TerminalSurfaceRegistry.shared
        let registeredOwnerId = registry.runtimeSurfaceOwnerId(surface)
        guard registeredOwnerId == id,
              cmuxSurfacePointerAppearsLive(surface) else {
            let callbackContext = surfaceCallbackContext
            surfaceCallbackContext = nil
            let teeContext = mobileByteTeeContext
            mobileByteTeeContext = nil
            registry.unregisterRuntimeSurface(surface, ownerId: id)
            self.surface = nil
            activePortalHostLease = nil
            recordTeardownRequest(reason: reason)
            markPortalLifecycleClosed(reason: reason)
#if DEBUG
            let registeredOwnerToken = registeredOwnerId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            cmuxDebugLog(
                "surface.lifecycle.stale surface=\(id.uuidString.prefix(5)) " +
                "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason) " +
                "registryOwner=\(registeredOwnerToken)"
            )
#endif
            callbackContext?.release()
            teeContext?.release()
            return nil
        }
        return surface
    }

    /// Forward a mobile scroll gesture to this real surface. libghostty does the
    /// mode-correct thing: a normal screen moves the viewport into scrollback;
    /// an alt screen with mouse reporting encodes mouse-wheel to the PTY for the
    /// program (vim/less/htop). `col`/`row` is the grid cell under the finger so
    /// the alt-screen wheel reports at the right cell. Runs on the main actor
    /// like the desktop's own scroll path.
    @MainActor
    func mobileScroll(deltaLines: Double, col: Int, row: Int) {
        guard deltaLines != 0,
              let surface = liveSurfaceForGhosttyAccess(reason: "mobileScroll") else { return }
        let size = ghostty_surface_size(surface)
        // The surface is sized in backing pixels; `ghostty_surface_mouse_pos`
        // wants points, so divide the cell size by the content scale.
        let scale = max(Double(lastXScale), 1)
        let cellWidthPt = Double(size.cell_width_px) / scale
        let cellHeightPt = Double(size.cell_height_px) / scale
        let posX = (Double(col) + 0.5) * cellWidthPt
        let posY = (Double(row) + 0.5) * cellHeightPt
        ghostty_surface_mouse_pos(surface, posX, posY, GHOSTTY_MODS_NONE)
        ghostty_surface_mouse_scroll(surface, 0, deltaLines, 0)
    }

    /// Forward a mobile tap to this real surface as a left mouse click at the
    /// given grid cell. libghostty does the mode-correct thing: a program with
    /// mouse reporting (alt-screen TUIs like lazygit/htop/fzf) gets an encoded
    /// click report to its PTY; a normal screen treats it as an empty selection,
    /// which is harmless. `col`/`row` is the grid cell under the finger. Runs on
    /// the main actor like the desktop's own click path.
    @MainActor
    func mobileClick(col: Int, row: Int) {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "mobileClick") else { return }
        let size = ghostty_surface_size(surface)
        // The surface is sized in backing pixels; `ghostty_surface_mouse_pos`
        // wants points, so divide the cell size by the content scale. Aim at the
        // cell center so the click lands unambiguously inside the target cell.
        let scale = max(Double(lastXScale), 1)
        let cellWidthPt = Double(size.cell_width_px) / scale
        let cellHeightPt = Double(size.cell_height_px) / scale
        let posX = (Double(max(0, col)) + 0.5) * cellWidthPt
        let posY = (Double(max(0, row)) + 0.5) * cellHeightPt
        ghostty_surface_mouse_pos(surface, posX, posY, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
    }

    private static let portalHostAreaThreshold: CGFloat = 4

    private static func portalHostArea(for bounds: CGRect) -> CGFloat {
        max(0, bounds.width) * max(0, bounds.height)
    }

    private static func portalHostIsUsable(_ lease: PortalHostLease) -> Bool {
        lease.inWindow && lease.area > portalHostAreaThreshold
    }

    @discardableResult
    func preparePortalHostReplacementIfOwned(hostId: ObjectIdentifier, reason: String) -> Bool {
        guard let current = activePortalHostLease, current.hostId == hostId else { return false }
        // SwiftUI can tear down and rebuild the host NSView during split churn. Keep the
        // existing portal binding alive, but make the old lease non-usable so the next
        // distinct host in the same pane can claim immediately instead of waiting for a
        // later layout-follow-up retry.
        activePortalHostLease = PortalHostLease(
            hostId: current.hostId,
            paneId: current.paneId,
            instanceSerial: current.instanceSerial,
            inWindow: false,
            area: current.area
        )
#if DEBUG
        cmuxDebugLog(
            "terminal.portal.host.rearm surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(current.paneId.uuidString.prefix(5)) " +
            "area=\(String(format: "%.1f", current.area))"
        )
#endif
        return true
    }

    func claimPortalHost(
        hostId: ObjectIdentifier,
        paneId: PaneID,
        instanceSerial: UInt64,
        inWindow: Bool,
        bounds: CGRect,
        reason: String
    ) -> Bool {
        let next = PortalHostLease(
            hostId: hostId,
            paneId: paneId.id,
            instanceSerial: instanceSerial,
            inWindow: inWindow,
            area: Self.portalHostArea(for: bounds)
        )

        if let current = activePortalHostLease {
            if current.hostId == hostId {
                activePortalHostLease = next
                return true
            }

            let currentUsable = Self.portalHostIsUsable(current)
            let nextUsable = Self.portalHostIsUsable(next)
            // During split churn SwiftUI can briefly keep the old host alive while the new
            // host for the same pane is already in the window. Prefer the newer live host
            // immediately so the surface moves with the pane instead of waiting for a later
            // update from unrelated focus/layout work.
            let newerSamePaneHostReady =
                current.paneId == paneId.id &&
                nextUsable &&
                next.instanceSerial > current.instanceSerial
            // A dragged terminal must hand off immediately when it moves to a different pane.
            // Waiting for the old host to become "worse" leaves the moved pane blank/stale.
            let shouldReplace =
                current.paneId != paneId.id ||
                !currentUsable ||
                newerSamePaneHostReady

            if shouldReplace {
#if DEBUG
                cmuxDebugLog(
                    "terminal.portal.host.claim surface=\(id.uuidString.prefix(5)) " +
                    "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                    "inWin=\(inWindow ? 1 : 0) " +
                    "size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                    "replacingHost=\(current.hostId) replacingPane=\(current.paneId.uuidString.prefix(5)) " +
                    "replacingInWin=\(current.inWindow ? 1 : 0) " +
                    "replacingArea=\(String(format: "%.1f", current.area))"
                )
#endif
                activePortalHostLease = next
                return true
            }

#if DEBUG
            cmuxDebugLog(
                "terminal.portal.host.skip surface=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                "inWin=\(inWindow ? 1 : 0) " +
                "size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                "ownerHost=\(current.hostId) ownerPane=\(current.paneId.uuidString.prefix(5)) " +
                "ownerInWin=\(current.inWindow ? 1 : 0) " +
                "ownerArea=\(String(format: "%.1f", current.area))"
            )
#endif
            return false
        }

        activePortalHostLease = next
#if DEBUG
        cmuxDebugLog(
            "terminal.portal.host.claim surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
            "inWin=\(inWindow ? 1 : 0) " +
            "size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) replacingHost=nil"
        )
#endif
        return true
    }

    func releasePortalHostIfOwned(hostId: ObjectIdentifier, reason: String) {
        guard let current = activePortalHostLease, current.hostId == hostId else { return }
        activePortalHostLease = nil
#if DEBUG
        cmuxDebugLog(
            "terminal.portal.host.release surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(current.paneId.uuidString.prefix(5)) " +
            "inWin=\(current.inWindow ? 1 : 0) " +
            "area=\(String(format: "%.1f", current.area))"
        )
#endif
    }

    private func recordTeardownRequest(reason: String) {
        withDebugMetadataLock {
            if teardownRequestedAt == nil {
                teardownRequestedAt = Date()
            }
            if let existing = teardownRequestReason, !existing.isEmpty {
                return
            }
            teardownRequestReason = reason
        }
    }

    private func recordRuntimeSurfaceCreation() {
        withDebugMetadataLock {
            runtimeSurfaceCreatedAt = Date()
        }
    }

    private func allowsRuntimeSurfaceCreation() -> Bool {
        portalLifecycleState == .live && !runtimeSurfaceSuspendedForAgentHibernation
    }

    private var hasDeferredStartupWork: Bool {
        let inheritedCommand = configTemplate?.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        let inheritedInput = configTemplate?.initialInput
        return initialCommand != nil ||
            tmuxStartCommand != nil ||
            initialInput != nil ||
            inheritedCommand?.isEmpty == false ||
            inheritedInput?.isEmpty == false ||
            pendingSocketInputBytes > 0
    }

    func hasDeferredStartupWorkForBackgroundStart() -> Bool {
        hasDeferredStartupWork
    }

    func beginPortalCloseLifecycle(reason: String) {
        guard portalLifecycleState != .closed else { return }
        guard portalLifecycleState != .closing else { return }
        recordTeardownRequest(reason: reason)
        portalLifecycleState = .closing
        portalLifecycleGeneration &+= 1
#if DEBUG
        cmuxDebugLog(
            "surface.lifecycle.close.begin surface=\(id.uuidString.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason) " +
            "generation=\(portalLifecycleGeneration)"
        )
#endif
    }

    private func markPortalLifecycleClosed(reason: String) {
        guard portalLifecycleState != .closed else { return }
        portalLifecycleState = .closed
        portalLifecycleGeneration &+= 1
#if DEBUG
        cmuxDebugLog(
            "surface.lifecycle.close.sealed surface=\(id.uuidString.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason) " +
            "generation=\(portalLifecycleGeneration)"
        )
#endif
    }

    /// Explicitly free the Ghostty runtime surface. Idempotent — safe to call
    /// before deinit; deinit will skip the free if already torn down.
    @MainActor
    func teardownSurface() {
        recordTeardownRequest(reason: "surface.teardown")
        markPortalLifecycleClosed(reason: "teardown")
        closeHeadlessStartupWindowIfNeeded()

        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil
        let teeContext = mobileByteTeeContext
        mobileByteTeeContext = nil
        MobileTerminalByteTee.shared.dropSurface(surfaceID: id)

        let surfaceToFree = surface
        if let surfaceToFree {
            TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        }
        surface = nil

        guard let surfaceToFree else {
            callbackContext?.release()
            teeContext?.release()
            return
        }

#if DEBUG
        if runtimeSurfaceFreedOutOfBandForTesting {
            runtimeSurfaceFreedOutOfBandForTesting = false
            callbackContext?.release()
            teeContext?.release()
            return
        }
#endif

#if DEBUG
        if let freeSurface = Self.runtimeSurfaceFreeOverrideForTesting {
            enqueueTerminalSurfaceRuntimeTeardown(
                id: id,
                workspaceId: tabId,
                reason: "teardown",
                surface: surfaceToFree,
                callbackContext: callbackContext,
                freeSurface: freeSurface
            )
            // The teardown coordinator releases callbackContext; teeContext is not
            // transported through the request, so release it here.
            teeContext?.release()
            return
        }
#endif

        Task { @MainActor in
            // Keep free behavior aligned with deinit: perform the runtime teardown on
            // the next main-actor turn so SIGHUP delivery is deterministic but non-reentrant.
            ghostty_surface_free(surfaceToFree)
            callbackContext?.release()
            teeContext?.release()
        }
    }

    @MainActor
    func suspendRuntimeSurfaceForAgentHibernation(reason: String) {
        runtimeSurfaceSuspendedForAgentHibernation = true
        backgroundSurfaceStartQueued = false
        closeHeadlessStartupWindowIfNeeded()
        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil
        let teeContext = mobileByteTeeContext
        mobileByteTeeContext = nil
        MobileTerminalByteTee.shared.dropSurface(surfaceID: id)

        let surfaceToFree = surface
        if let surfaceToFree {
            TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        }
        surface = nil
        activePortalHostLease = nil
        pendingSocketInputQueue.removeAll(keepingCapacity: false)
        pendingSocketInputBytes = 0
        desiredFocusState = false

        guard let surfaceToFree else {
            callbackContext?.release()
            teeContext?.release()
            return
        }

#if DEBUG
        cmuxDebugLog(
            "surface.lifecycle.hibernate surface=\(id.uuidString.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason)"
        )
#endif

#if DEBUG
        if let freeSurface = Self.runtimeSurfaceFreeOverrideForTesting {
            enqueueTerminalSurfaceRuntimeTeardown(
                id: id,
                workspaceId: tabId,
                reason: reason,
                surface: surfaceToFree,
                callbackContext: callbackContext,
                freeSurface: freeSurface
            )
            // The teardown coordinator releases callbackContext; teeContext is not
            // transported through the request, so release it here.
            teeContext?.release()
            return
        }
#endif

        Task { @MainActor in
            ghostty_surface_free(surfaceToFree)
            callbackContext?.release()
            teeContext?.release()
        }
    }

#if DEBUG
    private static let surfaceLogPath = "/tmp/cmux-ghostty-surface.log"
    private static let sizeLogPath = "/tmp/cmux-ghostty-size.log"

    func debugCurrentPixelSize() -> (width: UInt32, height: UInt32) {
        (lastPixelWidth, lastPixelHeight)
    }

    func debugDesiredFocusState() -> Bool {
        desiredFocusState
    }

    @MainActor
    func debugAdditionalEnvironmentForTesting() -> [String: String] {
        additionalEnvironment
    }

    func debugForceRefreshCount() -> Int {
        debugForceRefreshCountLock.lock()
        defer { debugForceRefreshCountLock.unlock() }
        return debugForceRefreshCountValue
    }

    @MainActor
    func resetDebugForceRefreshCount() {
        debugForceRefreshCountLock.lock()
        debugForceRefreshCountValue = 0
        debugForceRefreshCountLock.unlock()
    }

    private func recordDebugForceRefresh() {
        debugForceRefreshCountLock.lock()
        debugForceRefreshCountValue += 1
        debugForceRefreshCountLock.unlock()
    }

    private static func surfaceLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: surfaceLogPath) {
            defer { try? handle.close() }
            guard (try? handle.seekToEnd()) != nil else { return }
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            FileManager.default.createFile(atPath: surfaceLogPath, contents: line.data(using: .utf8))
        }
    }

    private static func sizeLog(_ message: String) {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] == "1" else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: sizeLogPath) {
            defer { try? handle.close() }
            guard (try? handle.seekToEnd()) != nil else { return }
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            FileManager.default.createFile(atPath: sizeLogPath, contents: line.data(using: .utf8))
        }
    }
    #endif

    /// Match upstream Ghostty AppKit sizing: framebuffer dimensions are derived
    /// from backing-space points and truncated (never rounded up).
    private func pixelDimension(from value: CGFloat) -> UInt32 {
        guard value.isFinite else { return 0 }
        let floored = floor(max(0, value))
        if floored >= CGFloat(UInt32.max) {
            return UInt32.max
        }
        return UInt32(floored)
    }

    private func scaleFactors(for view: GhosttyNSView) -> (x: CGFloat, y: CGFloat, layer: CGFloat) {
        let scale = max(
            1.0,
            view.window?.backingScaleFactor
                ?? view.layer?.contentsScale
                ?? NSScreen.main?.backingScaleFactor
                ?? 1.0
        )
        return (scale, scale, scale)
    }

    private func scaleApproximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs - rhs) <= epsilon
    }

    @MainActor
    func attachToView(_ view: GhosttyNSView) {
#if DEBUG
        cmuxDebugLog(
            "surface.attach surface=\(id.uuidString.prefix(5)) view=\(Unmanaged.passUnretained(view).toOpaque()) " +
            "attached=\(attachedView != nil ? 1 : 0) hasSurface=\(surface != nil ? 1 : 0) inWindow=\(view.window != nil ? 1 : 0)"
        )
#endif

        // If already attached to this view, nothing to do.
        // Still re-assert the display id: during split close tree restructuring, the view can be
        // removed/re-added (or briefly have window/screen nil) without recreating the surface.
        // Ghostty's vsync-driven renderer depends on having a valid display id; if it is missing
        // or stale, the surface can appear visually frozen until a focus/visibility change.
        // SwiftUI also re-enters this path for ordinary state propagation (drag hover, active
        // markers, visibility flags), so avoid forcing a geometry refresh when the attachment
        // itself is unchanged.
        if attachedView === view && surface != nil {
            releaseHeadlessStartupWindowIfNeeded(for: view)
#if DEBUG
            cmuxDebugLog("surface.attach.reuse surface=\(id.uuidString.prefix(5)) view=\(Unmanaged.passUnretained(view).toOpaque())")
#endif
            if let screen = view.window?.screen ?? NSScreen.main,
               let displayID = screen.displayID,
               displayID != 0,
               let s = surface {
                ghostty_surface_set_display_id(s, displayID)
            }
            return
        }

        if let attachedView, attachedView !== view {
#if DEBUG
            cmuxDebugLog(
                "surface.attach.skip surface=\(id.uuidString.prefix(5)) reason=alreadyAttachedToDifferentView " +
                "current=\(Unmanaged.passUnretained(attachedView).toOpaque()) new=\(Unmanaged.passUnretained(view).toOpaque())"
            )
#endif
            return
        }

        attachedView = view
        releaseHeadlessStartupWindowIfNeeded(for: view)

        // Ordinary portal attachment can arrive before AppKit has put the view in
        // a window. Defer those. Startup and cold-input paths install the owned
        // view in a hidden bootstrap window first, then come through here.
        if surface == nil {
            guard allowsRuntimeSurfaceCreation() else {
#if DEBUG
                cmuxDebugLog(
                    "surface.attach.skip surface=\(id.uuidString.prefix(5)) " +
                    "reason=lifecycle.\(portalLifecycleState.rawValue)"
                )
#endif
                return
            }
            guard view.window != nil else {
#if DEBUG
                cmuxDebugLog(
                    "surface.attach.defer surface=\(id.uuidString.prefix(5)) reason=noWindow " +
                    "bounds=\(String(format: "%.1fx%.1f", Double(view.bounds.width), Double(view.bounds.height)))"
                )
#endif
                return
            }
#if DEBUG
            cmuxDebugLog(
                "surface.attach.create surface=\(id.uuidString.prefix(5)) " +
                "inWindow=\(view.window != nil ? 1 : 0)"
            )
#endif
            createSurface(for: view)
#if DEBUG
            cmuxDebugLog("surface.attach.create.done surface=\(id.uuidString.prefix(5)) hasSurface=\(surface != nil ? 1 : 0)")
#endif
        } else if let screen = view.window?.screen ?? NSScreen.main,
                  let displayID = screen.displayID,
                  displayID != 0,
                  let s = surface {
            // Surface exists but we're (re)attaching after a view hierarchy move; ensure display id.
            ghostty_surface_set_display_id(s, displayID)
#if DEBUG
            cmuxDebugLog("surface.attach.displayId surface=\(id.uuidString.prefix(5)) display=\(displayID)")
#endif
        }
    }

    @MainActor
    private func claudeCommandShimStateForSurface(view: GhosttyNSView) -> (isReady: Bool, shim: ClaudeCommandShim?) {
        guard let wrapperURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux-claude-wrapper") else {
            claudeCommandShimInstallCompleted = true
            return (true, nil)
        }

        if claudeCommandShimInstallCompleted {
            return (true, claudeCommandShim)
        }

        if claudeCommandShimInstallTask == nil {
            let surfaceId = id
            let installTask = Task.detached(priority: .utility) {
                Self.installClaudeCommandShimIfPossible(wrapperURL: wrapperURL, surfaceId: surfaceId)
            }
            claudeCommandShimInstallTask = installTask
            Task { @MainActor [weak self, weak view] in
                let shim = await installTask.value
                guard let self else { return }
                self.claudeCommandShim = shim
                self.claudeCommandShimInstallCompleted = true
                self.claudeCommandShimInstallTask = nil
                guard self.allowsRuntimeSurfaceCreation(), self.surface == nil else { return }
                if let view, view.window != nil {
                    self.createSurface(for: view)
                } else if let attachedView = self.attachedView, attachedView.window != nil {
                    self.createSurface(for: attachedView)
                } else {
                    self.scheduleHeadlessRuntimeStartIfNeeded(reason: "claude-shim-ready")
                }
            }
        }

        return (false, nil)
    }

    @MainActor
    private func createSurface(for view: GhosttyNSView) {
        guard allowsRuntimeSurfaceCreation() else {
#if DEBUG
            cmuxDebugLog(
                "surface.create.skip surface=\(id.uuidString.prefix(5)) " +
                "reason=lifecycle.\(portalLifecycleState.rawValue)"
            )
            Self.surfaceLog(
                "createSurface SKIPPED surface=\(id.uuidString) tab=\(tabId.uuidString) lifecycle=\(portalLifecycleState.rawValue)"
            )
#endif
            return
        }
        let claudeShimState = claudeCommandShimStateForSurface(view: view)
        guard claudeShimState.isReady else { return }
        let claudeShim = claudeShimState.shim
#if DEBUG
        runtimeSurfaceCreateAttemptCountForTesting += 1
#endif
        #if DEBUG
        let resourcesDir = getenv("GHOSTTY_RESOURCES_DIR").flatMap { String(cString: $0) } ?? "(unset)"
        let terminfo = getenv("TERMINFO").flatMap { String(cString: $0) } ?? "(unset)"
        let xdg = getenv("XDG_DATA_DIRS").flatMap { String(cString: $0) } ?? "(unset)"
        let manpath = getenv("MANPATH").flatMap { String(cString: $0) } ?? "(unset)"
        Self.surfaceLog("createSurface start surface=\(id.uuidString) tab=\(tabId.uuidString) bounds=\(view.bounds) inWindow=\(view.window != nil) resources=\(resourcesDir) terminfo=\(terminfo) xdg=\(xdg) manpath=\(manpath)")
        #endif

        guard let app = GhosttyApp.shared.app else {
            #if DEBUG
            cmuxDebugLog("ghostty.surface.create.failed reason=appNotInitialized surface=\(id.uuidString)")
            #endif
            #if DEBUG
            Self.surfaceLog("createSurface FAILED surface=\(id.uuidString): ghostty app not initialized")
            #endif
            return
        }

        let scaleFactors = scaleFactors(for: view)

        var baseConfig = configTemplate ?? CmuxSurfaceConfigTemplate()
        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.font_size = baseConfig.fontSize
        surfaceConfig.wait_after_command = baseConfig.waitAfterCommand
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()
        ))
        let callbackContext = Unmanaged.passRetained(GhosttySurfaceCallbackContext(surfaceView: view, terminalSurface: self))
        surfaceConfig.userdata = callbackContext.toOpaque()
        surfaceCallbackContext?.release()
        surfaceCallbackContext = callbackContext
        surfaceConfig.scale_factor = scaleFactors.layer
        surfaceConfig.context = surfaceContext
#if DEBUG
        let templateFontText = String(format: "%.2f", surfaceConfig.font_size)
        cmuxDebugLog(
            "zoom.create surface=\(id.uuidString.prefix(5)) context=\(cmuxSurfaceContextName(surfaceContext)) " +
            "templateFont=\(templateFontText)"
        )
#endif
        var envVars: [ghostty_env_var_s] = []
        var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        defer {
            for (key, value) in envStorage {
                free(key)
                free(value)
            }
        }

        var env = baseConfig.environmentVariables

        var protectedStartupEnvironmentKeys: Set<String> = []
        Self.applyManagedTerminalIdentityEnvironment(
            to: &env,
            protectedKeys: &protectedStartupEnvironmentKeys
        )
        func setManagedEnvironmentValue(_ key: String, _ value: String) {
            env[key] = value
            protectedStartupEnvironmentKeys.insert(key)
        }

        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        Self.applyManagedCmuxContextEnvironment(
            Self.cmuxContextEnvironment(
                workspaceId: tabId,
                surfaceId: id,
                socketPath: socketPath
            ),
            to: &env,
            protectedKeys: &protectedStartupEnvironmentKeys
        )
        setManagedEnvironmentValue("CMUX_SOCKET", "")
        if let inheritedClaudeConfigDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !inheritedClaudeConfigDir.isEmpty {
            env["CLAUDE_CONFIG_DIR"] = ClaudeConfigDirectoryPath.preferredPath(inheritedClaudeConfigDir)
        }
        if let bundledCLIURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
           FileManager.default.isExecutableFile(atPath: bundledCLIURL.path) {
            setManagedEnvironmentValue("CMUX_BUNDLED_CLI_PATH", bundledCLIURL.path)
        }
        if let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty {
            setManagedEnvironmentValue("CMUX_BUNDLE_ID", bundleId)
        }

        // Port range for this workspace (base/range snapshotted once per app session)
        do {
            let startPort = Self.sessionPortBase + portOrdinal * Self.sessionPortRangeSize
            setManagedEnvironmentValue("CMUX_PORT", String(startPort))
            setManagedEnvironmentValue("CMUX_PORT_END", String(startPort + Self.sessionPortRangeSize - 1))
            setManagedEnvironmentValue("CMUX_PORT_RANGE", String(Self.sessionPortRangeSize))
        }

        let claudeHooksEnabled = ClaudeCodeIntegrationSettings.hooksEnabled()
        if !claudeHooksEnabled {
            setManagedEnvironmentValue("CMUX_CLAUDE_HOOKS_DISABLED", "1")
        }
        if let customClaudePath = ClaudeCodeIntegrationSettings.customClaudePath() {
            setManagedEnvironmentValue("CMUX_CUSTOM_CLAUDE_PATH", customClaudePath)
        }
        setManagedEnvironmentValue(
            AgentSubagentNotificationSettings.environmentKey,
            AgentSubagentNotificationSettings.suppressNotifications() ? "1" : "0"
        )
        if !CursorIntegrationSettings.hooksEnabled() {
            setManagedEnvironmentValue("CMUX_CURSOR_HOOKS_DISABLED", "1")
        }
        if !GeminiIntegrationSettings.hooksEnabled() {
            setManagedEnvironmentValue("CMUX_GEMINI_HOOKS_DISABLED", "1")
        }
        if !KiroIntegrationSettings.hooksEnabled() {
            setManagedEnvironmentValue("CMUX_KIRO_HOOKS_DISABLED", "1")
        }
        setManagedEnvironmentValue("CMUX_KIRO_NOTIFICATION_LEVEL", KiroIntegrationSettings.notificationLevel().rawValue)
        if !AmpIntegrationSettings.hooksEnabled() {
            setManagedEnvironmentValue("CMUX_AMP_HOOKS_DISABLED", "1")
        }

        if let cliBinPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            let currentPath = env["PATH"]
                ?? getenv("PATH").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? ""
            if !currentPath.split(separator: ":").contains(Substring(cliBinPath)) {
                setManagedEnvironmentValue(
                    "PATH",
                    Self.pathByPrependingUniqueDirectory(cliBinPath, to: currentPath)
                )
            }
        }

        if let claudeShim {
            setManagedEnvironmentValue("CMUX_CLAUDE_WRAPPER_SHIM", claudeShim.executablePath)
            setManagedEnvironmentValue("CMUX_CLAUDE_WRAPPER_SHIM_ROOT", claudeShim.directoryPath)
            let currentPath = env["PATH"]
                ?? getenv("PATH").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? ""
            setManagedEnvironmentValue(
                "PATH",
                Self.pathByPrependingUniqueDirectory(claudeShim.directoryPath, to: currentPath)
            )
        }

        // Shell integration: inject startup wrappers for supported shells.
        let shellIntegrationEnabled = UserDefaults.standard.object(forKey: "sidebarShellIntegration") as? Bool ?? true
        if shellIntegrationEnabled,
           let integrationDir = Bundle.main.resourceURL?.appendingPathComponent("shell-integration").path {
            setManagedEnvironmentValue("CMUX_SHELL_INTEGRATION", "1")
            setManagedEnvironmentValue("CMUX_SHELL_INTEGRATION_DIR", integrationDir)
            Self.applyManagedGitWatchEnvironment(
                watchGitStatusEnabled: SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard),
                showPullRequestsEnabled: SidebarWorkspaceDetailDefaults.showPullRequestsValue(defaults: .standard),
                to: &env,
                protectedKeys: &protectedStartupEnvironmentKeys
            )

            let shell = (env["SHELL"]?.isEmpty == false ? env["SHELL"] : nil)
                ?? getenv("SHELL").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["SHELL"]
                ?? "/bin/zsh"
            let shellName = URL(fileURLWithPath: shell).lastPathComponent
            if shellName == "zsh" {
                if GhosttyApp.shared.userGhosttyShellIntegrationMode != "none" {
                    setManagedEnvironmentValue("CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION", "1")
                }
                let candidateZdotdir = (env["ZDOTDIR"]?.isEmpty == false ? env["ZDOTDIR"] : nil)
                    ?? getenv("ZDOTDIR").map { String(cString: $0) }
                    ?? (ProcessInfo.processInfo.environment["ZDOTDIR"]?.isEmpty == false ? ProcessInfo.processInfo.environment["ZDOTDIR"] : nil)

                if let candidateZdotdir, !candidateZdotdir.isEmpty {
                    var isGhosttyInjected = false
                    let ghosttyResources = (env["GHOSTTY_RESOURCES_DIR"]?.isEmpty == false ? env["GHOSTTY_RESOURCES_DIR"] : nil)
                        ?? getenv("GHOSTTY_RESOURCES_DIR").map { String(cString: $0) }
                        ?? (ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]?.isEmpty == false ? ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] : nil)
                    if let ghosttyResources {
                        let ghosttyZdotdir = URL(fileURLWithPath: ghosttyResources)
                            .appendingPathComponent("shell-integration/zsh").path
                        isGhosttyInjected = (candidateZdotdir == ghosttyZdotdir)
                    }
                    if !isGhosttyInjected {
                        setManagedEnvironmentValue("CMUX_ZSH_ZDOTDIR", candidateZdotdir)
                    }
                }

                setManagedEnvironmentValue("ZDOTDIR", integrationDir)
            } else if shellName == "bash" {
                if GhosttyApp.shared.userGhosttyShellIntegrationMode != "none" {
                    setManagedEnvironmentValue("CMUX_LOAD_GHOSTTY_BASH_INTEGRATION", "1")
                }
                // macOS ships /bin/bash 3.2, where Ghostty's automatic bash
                // integration is unsupported and HOME-based wrapper startup is
                // not reliable. Bootstrap cmux bash integration on the first
                // interactive prompt by exporting the shared bootstrap script as
                // PROMPT_COMMAND. The script lives in Resources/shell-integration
                // so the app and the regression test share one source of truth
                // (see issue #5164). Doc comments and blank lines are stripped so
                // users never see them in $PROMPT_COMMAND; the test mirrors this.
                let bashBootstrapPath = (integrationDir as NSString)
                    .appendingPathComponent("cmux-bash-bootstrap.bash")
                do {
                    let rawBootstrap = try String(contentsOfFile: bashBootstrapPath, encoding: .utf8)
                    let bootstrap = rawBootstrap
                        .components(separatedBy: "\n")
                        .filter { line in
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
                        }
                        .joined(separator: "\n")
                    if !bootstrap.isEmpty {
                        setManagedEnvironmentValue("PROMPT_COMMAND", bootstrap)
                    }
                } catch {
                    // The bootstrap ships in the app bundle alongside
                    // cmux-bash-integration.bash, so a read failure means a
                    // corrupt/partial bundle. Surface it (with the underlying
                    // error) in unified logging rather than silently leaving bash
                    // without cmux integration. The path is logged privately so
                    // user-specific install paths are not exposed in the log.
                    Logger(subsystem: "com.cmuxterm.app", category: "ghostty.initialization")
                        .error("cmux bash bootstrap unreadable at \(bashBootstrapPath, privacy: .private): \(error.localizedDescription, privacy: .public); bash shell integration will not load")
                }
            } else if shellName == "fish" {
                Self.applyManagedFishStartupEnvironment(integrationDir: integrationDir, to: &env, protectedKeys: &protectedStartupEnvironmentKeys)
                if baseConfig.command?.isEmpty != false { baseConfig.command = Self.managedFishShellCommand(shell: shell) }
            }
        }
        env = Self.mergedStartupEnvironment(
            base: env,
            protectedKeys: protectedStartupEnvironmentKeys,
            additionalEnvironment: additionalEnvironment,
            initialEnvironmentOverrides: initialEnvironmentOverrides
        )
        env["CMUX_SOCKET"] = ""

        if !env.isEmpty {
            envVars.reserveCapacity(env.count)
            envStorage.reserveCapacity(env.count)
            for (key, value) in env {
                guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
                envStorage.append((keyPtr, valuePtr))
                envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
            }
        }

        let createSurface = { [self] in
            if !envVars.isEmpty {
                let envVarsCount = envVars.count
                envVars.withUnsafeMutableBufferPointer { buffer in
                    surfaceConfig.env_vars = buffer.baseAddress
                    surfaceConfig.env_var_count = envVarsCount
                    self.surface = ghostty_surface_new(app, &surfaceConfig)
                }
            } else {
                self.surface = ghostty_surface_new(app, &surfaceConfig)
            }
        }

        let resolvedWorkingDirectory: String? = {
            if let workingDirectory, !workingDirectory.isEmpty {
                return workingDirectory
            }
            return baseConfig.workingDirectory
        }()
        let resolvedCommand: String? = {
            if let initialCommand, !initialCommand.isEmpty {
                return initialCommand
            }
            return baseConfig.command
        }()
        let runtimeInitialInput = nextRuntimeInitialInput
        let resolvedInitialInput: String? = {
            if let runtimeInitialInput, !runtimeInitialInput.isEmpty {
                return runtimeInitialInput
            }
            if let initialInput, !initialInput.isEmpty {
                return initialInput
            }
            return baseConfig.initialInput
        }()
        func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
            guard let value else {
                return body(nil)
            }
            return value.withCString(body)
        }

        let createWithCommandAndWorkingDirectory = {
            withOptionalCString(resolvedCommand) { cCommand in
                surfaceConfig.command = cCommand
                withOptionalCString(resolvedWorkingDirectory) { cWorkingDir in
                    surfaceConfig.working_directory = cWorkingDir
                    withOptionalCString(resolvedInitialInput) { cInitialInput in
                        surfaceConfig.initial_input = cInitialInput
                        createSurface()
                    }
                }
            }
        }

        createWithCommandAndWorkingDirectory()

        if surface == nil {
            surfaceCallbackContext?.release()
            surfaceCallbackContext = nil
            #if DEBUG
            cmuxDebugLog("ghostty.surface.create.failed reason=surfaceNewNil surface=\(id.uuidString)")
            #endif
            #if DEBUG
            Self.surfaceLog("createSurface FAILED surface=\(id.uuidString): ghostty_surface_new returned nil")
            if let cfg = GhosttyApp.shared.config {
                let count = Int(ghostty_config_diagnostics_count(cfg))
                Self.surfaceLog("createSurface diagnostics count=\(count)")
                for i in 0..<count {
                    let diag = ghostty_config_get_diagnostic(cfg, UInt32(i))
                    let msg = diag.message.flatMap { String(cString: $0) } ?? "(null)"
                    Self.surfaceLog("  [\(i)] \(msg)")
                }
            } else {
                Self.surfaceLog("createSurface diagnostics: config=nil")
            }
            #endif
            return
        }
        guard let createdSurface = surface else { return }
        TerminalSurfaceRegistry.shared.registerRuntimeSurface(createdSurface, ownerId: id)
        recordRuntimeSurfaceCreation()
        // Install the PTY tee so MobileTerminalByteTee receives every byte
        // the read thread produces, in order, before the VT parser runs.
        // Paired iPhones consume these bytes via `terminal.bytes` events
        // and feed them into their own libghostty surface, guaranteeing
        // grid parity by construction. The userdata box is released
        // alongside `surfaceCallbackContext` when the surface tears down.
        mobileByteTeeContext?.release()
        let teeContext = Unmanaged.passRetained(MobileTerminalByteTeeUserdata(surfaceID: id))
        ghostty_surface_set_pty_tee_cb(
            createdSurface,
            cmuxMobileTerminalByteTeeCallback,
            teeContext.toOpaque()
        )
        mobileByteTeeContext = teeContext
        if runtimeInitialInput != nil {
            nextRuntimeInitialInput = nil
        }

        // Session scrollback replay must be one-shot. Reusing it on a later runtime
        // surface recreation would inject stale restored output into a live shell.
        additionalEnvironment.removeValue(forKey: SessionScrollbackReplayStore.environmentKey)

        // For vsync-driven rendering, Ghostty needs to know which display we're on so it can
        // start a CVDisplayLink with the right refresh rate. If we don't set this early, the
        // renderer can believe vsync is "running" but never deliver frames, which looks like a
        // frozen terminal until focus/visibility changes force a synchronous draw.
        //
        // `view.window?.screen` can be transiently nil during early attachment; fall back to the
        // primary screen so we always set *some* display ID, then update again on screen changes.
        if let screen = view.window?.screen ?? NSScreen.main,
           let displayID = screen.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(createdSurface, displayID)
        }

        ghostty_surface_set_content_scale(createdSurface, scaleFactors.x, scaleFactors.y)
        let backingSize = view.convertToBacking(NSRect(origin: .zero, size: view.bounds.size)).size
        let wpx = pixelDimension(from: backingSize.width)
        let hpx = pixelDimension(from: backingSize.height)
        if wpx > 0, hpx > 0 {
            ghostty_surface_set_size(createdSurface, wpx, hpx)
            lastPixelWidth = wpx
            lastPixelHeight = hpx
            lastUncappedPixelWidth = wpx
            lastUncappedPixelHeight = hpx
            lastXScale = scaleFactors.x
            lastYScale = scaleFactors.y
        }

        // Some GhosttyKit builds can drop inherited font_size during post-create
        // config/scale reconciliation. If runtime points don't match the inherited
        // template points, re-apply via binding action so all creation paths
        // (new surface, split, new workspace) preserve zoom from the source terminal.
        if let inheritedFontPoints = configTemplate?.fontSize,
           inheritedFontPoints > 0 {
            let currentFontPoints = cmuxCurrentSurfaceFontSizePoints(createdSurface)
            let shouldReapply = {
                guard let currentFontPoints else { return true }
                return abs(currentFontPoints - inheritedFontPoints) > 0.05
            }()
            if shouldReapply {
                let action = String(format: "set_font_size:%.3f", inheritedFontPoints)
                _ = performBindingAction(action)
            }
        }

        // Re-apply the desired focus state after creation so the live runtime
        // surface converges with any focus changes that happened while the
        // surface was being initialized.
        ghostty_surface_set_focus(createdSurface, desiredFocusState)

        flushPendingSocketInputIfNeeded()

        // Kick an initial draw after creation/size setup. On some startup paths Ghostty can
        // miss the first vsync callback and sit on a blank frame until another focus/visibility
        // transition nudges the renderer.
        view.forceRefreshSurface()
        ghostty_surface_refresh(createdSurface)

        NotificationCenter.default.post(
            name: .terminalSurfaceDidBecomeReady,
            object: self,
            userInfo: [
                "surfaceId": id,
                "workspaceId": tabId
            ]
        )

#if DEBUG
        let runtimeFontText = cmuxCurrentSurfaceFontSizePoints(createdSurface).map {
            String(format: "%.2f", $0)
        } ?? "nil"
        cmuxDebugLog(
            "zoom.create.done surface=\(id.uuidString.prefix(5)) context=\(cmuxSurfaceContextName(surfaceContext)) " +
            "runtimeFont=\(runtimeFontText)"
        )
#endif
    }

    @discardableResult
    @MainActor
    func updateSize(
        width: CGFloat,
        height: CGFloat,
        xScale: CGFloat,
        yScale: CGFloat,
        layerScale: CGFloat,
        backingSize: CGSize? = nil
    ) -> Bool {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "updateSize") else { return false }
        _ = layerScale

        let resolvedBackingWidth = backingSize?.width ?? (width * xScale)
        let resolvedBackingHeight = backingSize?.height ?? (height * yScale)
        let rawWpx = pixelDimension(from: resolvedBackingWidth)
        let rawHpx = pixelDimension(from: resolvedBackingHeight)
        lastUncappedPixelWidth = rawWpx
        lastUncappedPixelHeight = rawHpx
        let cappedSize = cappedByMobileViewportLimit(width: rawWpx, height: rawHpx, surface: surface)
        let wpx = cappedSize.width
        let hpx = cappedSize.height
        guard wpx > 0, hpx > 0 else { return false }

        let scaleChanged = !scaleApproximatelyEqual(xScale, lastXScale) || !scaleApproximatelyEqual(yScale, lastYScale)
        let sizeChanged = wpx != lastPixelWidth || hpx != lastPixelHeight

        #if DEBUG
        Self.sizeLog("updateSize-call surface=\(id.uuidString.prefix(8)) size=\(wpx)x\(hpx) prev=\(lastPixelWidth)x\(lastPixelHeight) changed=\((scaleChanged || sizeChanged) ? 1 : 0)")
        #endif

        if mobileViewportCellLimit != nil {
            updateMobileViewportBorder(
                appliedWidth: wpx,
                appliedHeight: hpx,
                baseWidth: rawWpx,
                baseHeight: rawHpx
            )
        }

        guard scaleChanged || sizeChanged else { return false }

        #if DEBUG
        if sizeChanged {
            let win = attachedView?.window != nil ? "1" : "0"
            Self.sizeLog("updateSize surface=\(id.uuidString.prefix(8)) size=\(wpx)x\(hpx) prev=\(lastPixelWidth)x\(lastPixelHeight) win=\(win)")
        }
        #endif

        if scaleChanged {
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            lastXScale = xScale
            lastYScale = yScale
        }

        if sizeChanged {
            ghostty_surface_set_size(surface, wpx, hpx)
            lastPixelWidth = wpx
            lastPixelHeight = hpx
        }

        // Let Ghostty continue rendering on its own wakeups for steady-state frames.
        return true
    }

    @discardableResult
    @MainActor
    func applyMobileViewportLimit(columns: Int, rows: Int, reason: String) -> Bool {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "applyMobileViewportLimit") else {
            hostedView.setMobileViewportBorder(size: nil, drawRight: false, drawBottom: false)
            return false
        }
        let size = ghostty_surface_size(surface)
        let cellWidth = max(1, Int(size.cell_width_px))
        let cellHeight = max(1, Int(size.cell_height_px))
        let currentColumns = max(1, Int(size.columns))
        let currentRows = max(1, Int(size.rows))
        let horizontalNonGridPixels = max(0, Int(size.width_px) - currentColumns * cellWidth)
        let verticalNonGridPixels = max(0, Int(size.height_px) - currentRows * cellHeight)
        let targetWidth = safePixelDimension(
            cellCount: columns,
            cellSize: cellWidth,
            nonGridPixels: horizontalNonGridPixels
        )
        let targetHeight = safePixelDimension(
            cellCount: rows,
            cellSize: cellHeight,
            nonGridPixels: verticalNonGridPixels
        )

        mobileViewportCellLimit = (columns: max(1, columns), rows: max(1, rows))
        let baseWidth = lastUncappedPixelWidth > 0 ? lastUncappedPixelWidth : targetWidth
        let baseHeight = lastUncappedPixelHeight > 0 ? lastUncappedPixelHeight : targetHeight
        let appliedWidth = min(targetWidth, baseWidth)
        let appliedHeight = min(targetHeight, baseHeight)
        let sizeChanged = appliedWidth != lastPixelWidth || appliedHeight != lastPixelHeight
        updateMobileViewportBorder(
            appliedWidth: appliedWidth,
            appliedHeight: appliedHeight,
            baseWidth: baseWidth,
            baseHeight: baseHeight
        )

        #if DEBUG
        Self.sizeLog(
            "mobileViewportLimit surface=\(id.uuidString.prefix(8)) cells=\(columns)x\(rows) " +
            "capPx=\(targetWidth)x\(targetHeight) appliedPx=\(appliedWidth)x\(appliedHeight) " +
            "basePx=\(baseWidth)x\(baseHeight) prev=\(lastPixelWidth)x\(lastPixelHeight) " +
            "changed=\(sizeChanged ? 1 : 0) reason=\(reason)"
        )
        #endif

        guard sizeChanged else { return false }
        ghostty_surface_set_size(surface, appliedWidth, appliedHeight)
        lastPixelWidth = appliedWidth
        lastPixelHeight = appliedHeight
        ghostty_surface_refresh(surface)
        return true
    }

    @discardableResult
    @MainActor
    func clearMobileViewportLimit(reason: String) -> Bool {
        mobileViewportCellLimit = nil
        hostedView.setMobileViewportBorder(size: nil, drawRight: false, drawBottom: false)

        let uncappedWidth = lastUncappedPixelWidth
        let uncappedHeight = lastUncappedPixelHeight
        guard let surface = liveSurfaceForGhosttyAccess(reason: "clearMobileViewportLimit"),
              uncappedWidth > 0,
              uncappedHeight > 0 else {
            return false
        }

        let sizeChanged = uncappedWidth != lastPixelWidth || uncappedHeight != lastPixelHeight

        #if DEBUG
        Self.sizeLog(
            "clearMobileViewportLimit surface=\(id.uuidString.prefix(8)) " +
            "uncappedPx=\(uncappedWidth)x\(uncappedHeight) prev=\(lastPixelWidth)x\(lastPixelHeight) " +
            "changed=\(sizeChanged ? 1 : 0) reason=\(reason)"
        )
        #endif

        guard sizeChanged else {
            ghostty_surface_refresh(surface)
            return false
        }
        ghostty_surface_set_size(surface, uncappedWidth, uncappedHeight)
        lastPixelWidth = uncappedWidth
        lastPixelHeight = uncappedHeight
        ghostty_surface_refresh(surface)
        return true
    }

    private func cappedByMobileViewportLimit(
        width: UInt32,
        height: UInt32,
        surface: ghostty_surface_t
    ) -> (width: UInt32, height: UInt32) {
        guard let mobileViewportPixelLimit = mobileViewportPixelLimit(for: surface) else {
            return (width, height)
        }
        return (
            width: min(width, mobileViewportPixelLimit.width),
            height: min(height, mobileViewportPixelLimit.height)
        )
    }

    private func mobileViewportPixelLimit(for surface: ghostty_surface_t) -> (width: UInt32, height: UInt32)? {
        guard let mobileViewportCellLimit else {
            return nil
        }
        let size = ghostty_surface_size(surface)
        let cellWidth = max(1, Int(size.cell_width_px))
        let cellHeight = max(1, Int(size.cell_height_px))
        let currentColumns = max(1, Int(size.columns))
        let currentRows = max(1, Int(size.rows))
        let horizontalNonGridPixels = max(0, Int(size.width_px) - currentColumns * cellWidth)
        let verticalNonGridPixels = max(0, Int(size.height_px) - currentRows * cellHeight)
        return (
            width: safePixelDimension(
                cellCount: mobileViewportCellLimit.columns,
                cellSize: cellWidth,
                nonGridPixels: horizontalNonGridPixels
            ),
            height: safePixelDimension(
                cellCount: mobileViewportCellLimit.rows,
                cellSize: cellHeight,
                nonGridPixels: verticalNonGridPixels
            )
        )
    }

    private func safePixelDimension(cellCount: Int, cellSize: Int, nonGridPixels: Int) -> UInt32 {
        let clampedCellSize = max(1, cellSize)
        let clampedNonGridPixels = min(max(0, nonGridPixels), Int(UInt32.max) - 1)
        let maxCells = max(1, (Int(UInt32.max) - clampedNonGridPixels) / clampedCellSize)
        let clampedCellCount = min(max(1, cellCount), maxCells)
        return UInt32(clampedCellCount * clampedCellSize + clampedNonGridPixels)
    }

    private func updateMobileViewportBorder(
        appliedWidth: UInt32,
        appliedHeight: UInt32,
        baseWidth: UInt32,
        baseHeight: UInt32
    ) {
        let drawRightBorder = appliedWidth < baseWidth
        let drawBottomBorder = appliedHeight < baseHeight
        let borderScale = hostedView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        hostedView.setMobileViewportBorder(
            size: CGSize(
                width: CGFloat(appliedWidth) / max(1, borderScale),
                height: CGFloat(appliedHeight) / max(1, borderScale)
            ),
            drawRight: drawRightBorder,
            drawBottom: drawBottomBorder
        )
    }

    /// Force a full size recalculation and surface redraw.
    @MainActor
    func forceRefresh(reason: String = "unspecified") {
#if DEBUG
        let hasSurface = surface != nil
        let viewState: String
        if let view = attachedView {
            let inWindow = uiWindow != nil
            let bounds = view.bounds
            let metalOK = (view.layer as? CAMetalLayer) != nil
            viewState = "inWindow=\(inWindow) bounds=\(bounds) metalOK=\(metalOK) hasSurface=\(hasSurface)"
        } else {
            viewState = "NO_ATTACHED_VIEW hasSurface=\(hasSurface)"
        }
        cmuxDebugLog("forceRefresh: \(id) reason=\(reason) \(viewState)")
#endif
        guard let view = attachedView,
              let window = uiWindow,
              view.bounds.width > 0,
              view.bounds.height > 0 else {
            return
        }
#if DEBUG
        recordDebugForceRefresh()
#endif
        // Re-read self.surface before each ghostty call to guard against the surface
        // being freed during wake-from-sleep geometry reconciliation (issue #432).
        // The surface can be invalidated between calls when AppKit layout triggers
        // view lifecycle changes (e.g., forceRefreshSurface → layout → deinit → free).

        // Reassert display id on topology churn (split close/reparent) before forcing a refresh.
        // This avoids a first-run stuck-vsync state where Ghostty believes vsync is active
        // but callbacks have not resumed for the current display.
        let displayID = (window.screen ?? NSScreen.main)?.displayID
#if DEBUG
        let accessReason = "forceRefresh.\(reason)"
#else
        let accessReason = "forceRefresh"
#endif
        guard let currentSurface = liveSurfaceForGhosttyAccess(reason: accessReason) else {
            return
        }
        if let displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(currentSurface, displayID)
        }

        view.forceRefreshSurface()
#if DEBUG
        let refreshReason = "forceRefresh.refresh.\(reason)"
#else
        let refreshReason = "forceRefresh.refresh"
#endif
        guard let surface = liveSurfaceForGhosttyAccess(reason: refreshReason) else {
            return
        }
        ghostty_surface_refresh(surface)
    }

    func applyWindowBackgroundIfActive() {
        surfaceView.applyWindowBackgroundIfActive()
    }

    /// Keep `desiredFocusState` in sync when the hosted view's responder chain
    /// calls `ghostty_surface_set_focus` directly (bypassing `setFocus`).
    /// Without this, `createSurface` would replay a stale state on recreation.
    func recordExternalFocusState(_ focused: Bool) {
        desiredFocusState = focused
    }

    func setFocus(_ focused: Bool, force: Bool = false) {
        // Only send focus events when the state changes to avoid redundant
        // prompt redraws with zsh themes like Powerlevel10k.
        guard force || focused != desiredFocusState else { return }
        desiredFocusState = focused
        // Track desired state even before the C surface exists (e.g. during
        // layout restoration). createSurface syncs the state once created.
        guard let surface = surface else { return }
        ghostty_surface_set_focus(surface, focused)

        // If we focus a surface while it is being rapidly reparented (closing splits, etc),
        // Ghostty's CVDisplayLink can end up started before the display id is valid, leaving
        // hasVsync() true but with no callbacks ("stuck-vsync-no-frames"). Reasserting the
        // display id *after* focusing lets Ghostty restart the display link when needed.
        if focused {
            if let view = attachedView,
               let displayID = (view.window?.screen ?? NSScreen.main)?.displayID,
               displayID != 0 {
                ghostty_surface_set_display_id(surface, displayID)
            }
        }
    }

    func prepareNextRuntimeInitialInput(_ input: String?) {
        let trimmedInput = input?.isEmpty == false ? input : nil
        nextRuntimeInitialInput = trimmedInput
    }

    @MainActor
    func prepareAgentHibernationResume(initialInput: String?) {
        runtimeSurfaceSuspendedForAgentHibernation = false
        prepareNextRuntimeInitialInput(initialInput)
    }

    func setOcclusion(_ visible: Bool) {
        guard let surface = surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    func needsConfirmClose() -> Bool {
#if DEBUG
        if let needsConfirmCloseOverrideForTesting {
            return needsConfirmCloseOverrideForTesting
        }
#endif
        guard let surface = surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    func noteClipboardReadCompleted() {
        clipboardReadGeneration += 1
        NotificationCenter.default.post(
            name: .terminalSurfaceDidCompleteClipboardRead,
            object: self
        )
    }

    @MainActor
    @discardableResult
    func sendText(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return true }
        guard surface != nil else {
            guard allowsRuntimeSurfaceCreation() else { return false }
            let queued = enqueuePendingSocketInput(.pasteText(data))
            if queued {
                recordAgentHibernationTerminalInput(workspaceId: tabId, panelId: id)
                requestBackgroundSurfaceStartIfNeeded()
            }
            return queued
        }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendText") else {
            return false
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return false }
        recordAgentHibernationTerminalInput(workspaceId: tabId, panelId: id)
        writeTextData(data, to: liveSurface)
        return true
    }

    @MainActor
    @discardableResult
    func sendKeyText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendKeyText") else {
            return false
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return false }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = 0
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        return text.withCString { ptr in
            keyEvent.text = ptr
            return ghostty_surface_key(liveSurface, keyEvent)
        }
    }

    @MainActor
    @discardableResult
    func sendNamedKey(_ keyName: String) -> NamedKeySendResult {
        guard let event = pendingKeyEvent(for: keyName) else { return .unknownKey }
        guard surface != nil else {
            guard allowsRuntimeSurfaceCreation() else { return .surfaceUnavailable }
            guard enqueuePendingSocketInput(.key(event)) else { return .inputQueueFull }
            recordAgentHibernationTerminalInput(workspaceId: tabId, panelId: id)
            requestBackgroundSurfaceStartIfNeeded()
            return .queued
        }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendNamedKey") else {
            return .surfaceUnavailable
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return .processExited }
        recordAgentHibernationTerminalInput(workspaceId: tabId, panelId: id)
        sendKeyEvent(surface: liveSurface, keycode: event.keycode, mods: event.mods)
        return .sent
    }

    @MainActor
    func visibleText() -> String? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "visibleText") else { return nil }
        return Self.readText(surface: surface, pointTag: GHOSTTY_POINT_VIEWPORT)
    }

    @MainActor
    func mobileRenderGridFrame(
        stateSeq: UInt64,
        full: Bool = true,
        changedRows: Set<Int>? = nil,
        scrollbackLines: Int = 0
    ) -> (frame: MobileTerminalRenderGridFrame, rows: [String])? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "mobileRenderGrid") else { return nil }
        let surfaceID = id.uuidString
        let exported = surfaceID.withCString { ptr in
            ghostty_surface_render_grid_json(
                surface,
                ptr,
                UInt(surfaceID.utf8.count),
                stateSeq,
                UInt(max(0, scrollbackLines))
            )
        }
        defer { ghostty_string_free(exported) }
        guard let ptr = exported.ptr, exported.len > 0 else { return nil }

        let data = Data(bytes: ptr, count: Int(exported.len))
        guard let fullFrame = try? JSONDecoder().decode(MobileTerminalRenderGridFrame.self, from: data) else {
            return nil
        }
        let frame: MobileTerminalRenderGridFrame
        if full, changedRows == nil {
            frame = fullFrame
        } else {
            let includedRows = changedRows ?? Set(0..<fullFrame.rows)
            guard let filtered = try? fullFrame.filteredRows(includedRows, full: full) else {
                return nil
            }
            frame = filtered
        }
        return (frame, frame.plainRows())
    }

    /// Send text with control characters (Return, Tab, etc.) delivered as key
    /// events so the shell processes them, while complete terminal control
    /// sequences are routed through Ghostty's PTY-output parser. Cold surfaces
    /// queue the same ordered events and flush them after runtime creation.
    @MainActor
    @discardableResult
    func sendInput(_ text: String) -> Bool {
        return sendInputResult(text).accepted
    }

    @MainActor
    @discardableResult
    func sendInputResult(_ text: String) -> InputSendResult {
        guard !text.isEmpty else { return .sent }
        guard surface != nil else {
            guard allowsRuntimeSurfaceCreation() else { return .surfaceUnavailable }
            let queued = enqueuePendingSocketInput(text)
            if queued {
                recordAgentHibernationTerminalInput(workspaceId: tabId, panelId: id)
                requestBackgroundSurfaceStartIfNeeded()
            }
            return queued ? .queued : .inputQueueFull
        }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendInput") else {
            return .surfaceUnavailable
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return .processExited }
        recordAgentHibernationTerminalInput(workspaceId: tabId, panelId: id)
        sendInput(text, to: liveSurface)
        return .sent
    }

    @MainActor
    private func sendInput(_ text: String, to surface: ghostty_surface_t) {
        for event in Self.parsedSocketInputEvents(for: text) {
            switch event {
            case .rawBytes(let data):
                writeInputTextData(data, to: surface)
            case .terminalBytes(let data):
                writeProcessOutputData(data, to: surface)
            case .key(let event):
                sendKeyEvent(surface: surface, keycode: event.keycode, mods: event.mods)
            }
        }
    }

    @MainActor
    private func enqueuePendingSocketInput(_ text: String) -> Bool {
        let inputs = Self.parsedSocketInputEvents(for: text).compactMap { event -> PendingSocketInput? in
            switch event {
            case .rawBytes(let data):
                return data.isEmpty ? nil : .inputText(data)
            case .terminalBytes(let data):
                return data.isEmpty ? nil : .processOutput(data)
            case .key(let event):
                return .key(event)
            }
        }
        return enqueuePendingSocketInputs(inputs)
    }

    private static func parsedSocketInputEvents(for text: String) -> [ParsedSocketInput] {
        guard !text.isEmpty else { return [] }

        var events: [ParsedSocketInput] = []
        events.reserveCapacity(8)
        var bufferedText = ""
        bufferedText.reserveCapacity(text.count)
        var previousWasCR = false
        let scalars = Array(text.unicodeScalars)

        func flushBufferedText() {
            guard !bufferedText.isEmpty else { return }
            for chunk in committedTextInputChunks(from: bufferedText) {
                events.append(.rawBytes(chunk))
            }
            bufferedText.removeAll(keepingCapacity: true)
        }

        func appendKey(_ keycode: UInt32, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE, label: String) {
            events.append(.key(PendingKeyEvent(
                keycode: keycode,
                mods: mods,
                label: label
            )))
        }

        func appendRawReturn() {
            events.append(.rawBytes(Data([0x0D])))
        }

        func appendTerminalBytes(length: Int, from start: Int) {
            guard length > 0 else { return }
            var sequence = ""
            for offset in start..<(start + length) {
                sequence.unicodeScalars.append(scalars[offset])
            }
            guard let data = sequence.data(using: .utf8), !data.isEmpty else { return }
            events.append(.terminalBytes(data))
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x0A:
                if !previousWasCR {
                    flushBufferedText()
                    appendRawReturn()
                }
                previousWasCR = false
                index += 1
            case 0x0D:
                flushBufferedText()
                appendRawReturn()
                previousWasCR = true
                index += 1
            case 0x09:
                flushBufferedText()
                appendKey(UInt32(kVK_Tab), label: "tab")
                previousWasCR = false
                index += 1
            case 0x1B:
                // A bare ESC is the Escape key. But a full CSI/SS3 navigation
                // sequence arriving as raw input (the iOS on-screen arrows send
                // ESC[B, etc.) must stay one key press, or the terminal receives
                // Escape followed by literal "[B". Re-issue recognized sequences
                // as key events so libghostty encodes them for the surface's
                // current cursor-key mode, exactly like a hardware arrow press.
                if let nav = navigationEscapeKey(scalars, from: index) {
                    flushBufferedText()
                    appendKey(nav.keycode, mods: nav.mods, label: nav.label)
                    index += nav.length
                } else if let length = terminalControlSequenceLength(scalars, from: index) {
                    flushBufferedText()
                    appendTerminalBytes(length: length, from: index)
                    index += length
                } else {
                    flushBufferedText()
                    appendKey(UInt32(kVK_Escape), label: "escape")
                    index += 1
                }
                previousWasCR = false
            case 0x08, 0x7F:
                flushBufferedText()
                appendKey(UInt32(kVK_Delete), label: "backspace")
                previousWasCR = false
                index += 1
            default:
                bufferedText.unicodeScalars.append(scalar)
                previousWasCR = false
                index += 1
            }
        }
        flushBufferedText()
        return events
    }

    /// Returns the byte-like scalar length for a complete terminal string control sequence.
    private static func terminalControlSequenceLength(
        _ scalars: [Unicode.Scalar],
        from start: Int
    ) -> Int? {
        guard start + 1 < scalars.count, scalars[start].value == 0x1B else { return nil }

        switch scalars[start + 1].value {
        case 0x5D: // OSC: ESC ] ... (BEL | ST)
            return stringControlSequenceLength(scalars, from: start, terminatesWithBEL: true)
        case 0x50, 0x5E, 0x5F: // DCS / PM / APC: ESC P/^/_ ... ST
            return stringControlSequenceLength(scalars, from: start, terminatesWithBEL: false)
        default:
            return nil
        }
    }

    /// Finds the terminator for ESC-prefixed string controls without accepting partial sequences.
    private static func stringControlSequenceLength(
        _ scalars: [Unicode.Scalar],
        from start: Int,
        terminatesWithBEL: Bool
    ) -> Int? {
        var index = start + 2
        while index < scalars.count {
            let value = scalars[index].value
            if terminatesWithBEL, value == 0x07 {
                return index - start + 1
            }
            if value == 0x1B,
               index + 1 < scalars.count,
               scalars[index + 1].value == 0x5C {
                return index - start + 2
            }
            index += 1
        }
        return nil
    }

    /// Match a CSI (`ESC [ …`) or SS3 (`ESC O …`) cursor/navigation escape
    /// sequence beginning at `start` (which points at the ESC, 0x1B). Returns
    /// the equivalent macOS key code and how many scalars the sequence consumed,
    /// or nil for a bare ESC or an unrecognized sequence (which stays the
    /// Escape key). Only unmodified navigation keys are mapped; the surface
    /// re-encodes them for its current DECCKM cursor-key mode.
    private static func navigationEscapeKey(
        _ scalars: [Unicode.Scalar],
        from start: Int
    ) -> (keycode: UInt32, mods: ghostty_input_mods_e, label: String, length: Int)? {
        guard start + 1 < scalars.count else { return nil }
        let next = scalars[start + 1].value
        // Meta+Backspace: the iOS app sends ESC 0x7F (or ESC 0x08) for
        // option-delete-word. Re-issue as Backspace with the Option modifier so
        // libghostty encodes the meta-backspace for the surface, instead of the
        // bare-ESC path splitting it into Escape + a plain backspace.
        if next == 0x7F || next == 0x08 {
            return (UInt32(kVK_Delete), GHOSTTY_MODS_ALT, "alt-backspace", 2)
        }
        // CSI (ESC[) / SS3 (ESCO) cursor + navigation sequences.
        guard next == 0x5B || next == 0x4F, start + 2 < scalars.count else { return nil }
        let final = scalars[start + 2].value
        switch final {
        case 0x41: return (UInt32(kVK_UpArrow), GHOSTTY_MODS_NONE, "up", 3)        // A
        case 0x42: return (UInt32(kVK_DownArrow), GHOSTTY_MODS_NONE, "down", 3)    // B
        case 0x43: return (UInt32(kVK_RightArrow), GHOSTTY_MODS_NONE, "right", 3)  // C
        case 0x44: return (UInt32(kVK_LeftArrow), GHOSTTY_MODS_NONE, "left", 3)    // D
        case 0x48: return (UInt32(kVK_Home), GHOSTTY_MODS_NONE, "home", 3)         // H
        case 0x46: return (UInt32(kVK_End), GHOSTTY_MODS_NONE, "end", 3)           // F
        default:
            break
        }
        // CSI tilde sequences: ESC [ N ~
        if next == 0x5B, start + 3 < scalars.count, scalars[start + 3].value == 0x7E {
            switch final {
            case 0x31: return (UInt32(kVK_Home), GHOSTTY_MODS_NONE, "home", 4)               // 1~
            case 0x33: return (UInt32(kVK_ForwardDelete), GHOSTTY_MODS_NONE, "forwardDelete", 4) // 3~
            case 0x34: return (UInt32(kVK_End), GHOSTTY_MODS_NONE, "end", 4)                 // 4~
            case 0x35: return (UInt32(kVK_PageUp), GHOSTTY_MODS_NONE, "pageUp", 4)           // 5~
            case 0x36: return (UInt32(kVK_PageDown), GHOSTTY_MODS_NONE, "pageDown", 4)       // 6~
            default:
                break
            }
        }
        return nil
    }

    private static func committedTextInputChunks(from text: String) -> [Data] {
        guard !text.isEmpty else { return [] }

        var chunks: [Data] = []
        chunks.reserveCapacity(max(1, (text.utf8.count / committedTextInputChunkByteLimit) + 1))
        var chunk = Data()
        chunk.reserveCapacity(committedTextInputChunkByteLimit)

        func flushChunk() {
            guard !chunk.isEmpty else { return }
            chunks.append(chunk)
            chunk.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            let scalarBytes = String(scalar).utf8
            if !chunk.isEmpty, chunk.count + scalarBytes.count > committedTextInputChunkByteLimit {
                flushChunk()
            }
            chunk.append(contentsOf: scalarBytes)
        }
        flushChunk()
        return chunks
    }

    // Canonical key text for synthetic key events sent from the mobile/socket
    // input path (see `sendKeyEvent`). The desktop `keyDown` handler fills
    // `ghostty_input_key_s.text` from `charactersIgnoringModifiers`; libghostty
    // needs that text to encode control keys whose byte is otherwise filtered by
    // the raw-text input path. Mobile builds the event from a bare keycode, so we
    // reproduce the same canonical text here, keyed purely off the keycode.
    //
    // Only Backspace/Delete and Tab need this: their physical macOS keys carry
    // the DEL (0x7F) and TAB (0x09) characters in `charactersIgnoringModifiers`.
    // The text is independent of modifiers (Option-Backspace still reports DEL),
    // so this intentionally ignores `mods`. Pure function keys (arrows, Home,
    // End, page navigation) carry no characters and correctly encode from the
    // keycode alone, so they return nil.
    private static func canonicalKeyText(keycode: UInt32) -> String? {
        switch keycode {
        case UInt32(kVK_Delete):
            return "\u{7F}"
        case UInt32(kVK_Tab):
            return "\t"
        default:
            return nil
        }
    }

    private func sendKeyEvent(
        surface: ghostty_surface_t,
        keycode: UInt32,
        mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE
    ) {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = keycode
        keyEvent.mods = mods
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.composing = false

        let canonicalText = Self.canonicalKeyText(keycode: keycode)
        keyEvent.unshifted_codepoint = canonicalText?.unicodeScalars.first?.value ?? 0

        let handled: Bool
        if let canonicalText {
            // Mirror the desktop `keyDown` path's C-string lifetime: the text
            // pointer must stay valid only for the `ghostty_surface_key` call.
            handled = canonicalText.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            handled = ghostty_surface_key(surface, keyEvent)
        }

#if DEBUG
        cmuxDebugLog(
            "surface.socket_input.key surface=\(id.uuidString.prefix(8)) " +
            "keycode=\(keycode) mods=\(mods.rawValue) " +
            "codepoint=0x\(String(keyEvent.unshifted_codepoint, radix: 16)) " +
            "handled=\(handled ? 1 : 0)"
        )
#endif
    }

    @MainActor
    private func liveSurfaceForSocketWrite(reason: String) -> ghostty_surface_t? {
        return liveSurfaceForGhosttyAccess(reason: reason)
    }

    // Socket/API operations are an explicit runtime demand: they must be able to
    // start a terminal in a background workspace without selecting that workspace.
    // When there is no real window yet, bootstrap Ghostty in a hidden window and
    // reconcile display/window state when the terminal is later presented.
    func requestBackgroundSurfaceStartIfNeeded() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.requestBackgroundSurfaceStartIfNeeded()
            }
            return
        }

        guard allowsRuntimeSurfaceCreation() else { return }
        guard surface == nil else { return }
        guard !backgroundSurfaceStartQueued else { return }
        backgroundSurfaceStartQueued = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.backgroundSurfaceStartQueued = false
                guard self.allowsRuntimeSurfaceCreation() else { return }
                guard self.surface == nil else { return }
            #if DEBUG
                let startedAt = ProcessInfo.processInfo.systemUptime
            #endif
                if let view = self.attachedView, view.window != nil {
                    self.createSurface(for: view)
                } else {
                    self.scheduleHeadlessRuntimeStartIfNeeded(reason: "background-input")
                }
            #if DEBUG
                let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
                let view = self.attachedView ?? self.surfaceView
                cmuxDebugLog(
                    "surface.background_start surface=\(self.id.uuidString.prefix(8)) inWindow=\(view.window != nil ? 1 : 0) ready=\(self.surface != nil ? 1 : 0) ms=\(String(format: "%.2f", elapsedMs))"
                )
            #endif
            }
        }
    }

    private func writeTextData(_ data: Data, to surface: ghostty_surface_t) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    private func writeInputTextData(_ data: Data, to surface: ghostty_surface_t) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text_input(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    /// Sends bytes through Ghostty's PTY-output parser so OSC commands affect terminal state.
    private func writeProcessOutputData(_ data: Data, to surface: ghostty_surface_t) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_process_output(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    private static func readText(
        surface: ghostty_surface_t,
        pointTag: ghostty_point_tag_e
    ) -> String? {
        let topLeft = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer {
            ghostty_surface_free_text(surface, &text)
        }

        guard let ptr = text.text, text.text_len > 0 else {
            return ""
        }
        let rawData = Data(bytes: ptr, count: Int(text.text_len))
        return String(decoding: rawData, as: UTF8.self)
    }

    private func keycodeForLetter(_ letter: Character) -> UInt32? {
        switch String(letter).lowercased() {
        case "a": return UInt32(kVK_ANSI_A)
        case "b": return UInt32(kVK_ANSI_B)
        case "c": return UInt32(kVK_ANSI_C)
        case "d": return UInt32(kVK_ANSI_D)
        case "e": return UInt32(kVK_ANSI_E)
        case "f": return UInt32(kVK_ANSI_F)
        case "g": return UInt32(kVK_ANSI_G)
        case "h": return UInt32(kVK_ANSI_H)
        case "i": return UInt32(kVK_ANSI_I)
        case "j": return UInt32(kVK_ANSI_J)
        case "k": return UInt32(kVK_ANSI_K)
        case "l": return UInt32(kVK_ANSI_L)
        case "m": return UInt32(kVK_ANSI_M)
        case "n": return UInt32(kVK_ANSI_N)
        case "o": return UInt32(kVK_ANSI_O)
        case "p": return UInt32(kVK_ANSI_P)
        case "q": return UInt32(kVK_ANSI_Q)
        case "r": return UInt32(kVK_ANSI_R)
        case "s": return UInt32(kVK_ANSI_S)
        case "t": return UInt32(kVK_ANSI_T)
        case "u": return UInt32(kVK_ANSI_U)
        case "v": return UInt32(kVK_ANSI_V)
        case "w": return UInt32(kVK_ANSI_W)
        case "x": return UInt32(kVK_ANSI_X)
        case "y": return UInt32(kVK_ANSI_Y)
        case "z": return UInt32(kVK_ANSI_Z)
        default: return nil
        }
    }

    private func keycodeForNamedKey(_ name: String) -> UInt32? {
        switch name {
        case "enter", "return": return UInt32(kVK_Return)
        case "tab": return UInt32(kVK_Tab)
        case "escape", "esc": return UInt32(kVK_Escape)
        case "backspace": return UInt32(kVK_Delete)
        case "delete": return UInt32(kVK_ForwardDelete)
        case "space": return UInt32(kVK_Space)
        case "up": return UInt32(kVK_UpArrow)
        case "down": return UInt32(kVK_DownArrow)
        case "left": return UInt32(kVK_LeftArrow)
        case "right": return UInt32(kVK_RightArrow)
        case "\\": return UInt32(kVK_ANSI_Backslash)
        default: return nil
        }
    }

    private func pendingKeyEvent(for keyName: String) -> PendingKeyEvent? {
        let normalized = keyName.lowercased()
        switch normalized {
        case "ctrl-c", "ctrl+c", "sigint":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_C), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-d", "ctrl+d", "eof":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_D), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-f", "ctrl+f":
            // Force-stop chord for embedded TUIs (e.g. Claude Code's "Ctrl-F twice").
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_F), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-z", "ctrl+z", "sigtstp":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_Z), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-\\", "ctrl+\\", "sigquit":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_Backslash), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "enter", "return":
            return PendingKeyEvent(keycode: UInt32(kVK_Return), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "tab":
            return PendingKeyEvent(keycode: UInt32(kVK_Tab), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "escape", "esc":
            return PendingKeyEvent(keycode: UInt32(kVK_Escape), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "backspace":
            return PendingKeyEvent(keycode: UInt32(kVK_Delete), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "up", "arrow_up", "arrowup":
            return PendingKeyEvent(keycode: UInt32(kVK_UpArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "down", "arrow_down", "arrowdown":
            return PendingKeyEvent(keycode: UInt32(kVK_DownArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "left", "arrow_left", "arrowleft":
            return PendingKeyEvent(keycode: UInt32(kVK_LeftArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "right", "arrow_right", "arrowright":
            return PendingKeyEvent(keycode: UInt32(kVK_RightArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "shift+tab", "shift-tab", "backtab":
            return PendingKeyEvent(keycode: UInt32(kVK_Tab), mods: GHOSTTY_MODS_SHIFT, label: normalized)
        case "home":
            return PendingKeyEvent(keycode: UInt32(kVK_Home), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "end":
            return PendingKeyEvent(keycode: UInt32(kVK_End), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "delete", "del", "forward_delete":
            return PendingKeyEvent(keycode: UInt32(kVK_ForwardDelete), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "pageup", "page_up":
            return PendingKeyEvent(keycode: UInt32(kVK_PageUp), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "pagedown", "page_down":
            return PendingKeyEvent(keycode: UInt32(kVK_PageDown), mods: GHOSTTY_MODS_NONE, label: normalized)
        default:
            let parts = normalized
                .split(separator: "+")
                .flatMap { $0.split(separator: "-") }
                .map(String.init)
                .filter { !$0.isEmpty }
            guard let baseKey = parts.last else { return nil }

            if parts.count == 1 {
                if let keycode = keycodeForNamedKey(baseKey) {
                    return PendingKeyEvent(keycode: keycode, mods: GHOSTTY_MODS_NONE, label: normalized)
                }
                if baseKey.count == 1,
                   let char = baseKey.first,
                   let keycode = keycodeForLetter(char) {
                    return PendingKeyEvent(keycode: keycode, mods: GHOSTTY_MODS_NONE, label: normalized)
                }
                return nil
            }

            var mods = GHOSTTY_MODS_NONE
            for mod in parts.dropLast() {
                switch mod {
                case "ctrl", "control":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_CTRL.rawValue)
                case "shift":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
                case "alt", "opt", "option":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_ALT.rawValue)
                case "cmd", "command", "super":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SUPER.rawValue)
                default:
                    return nil
                }
            }

            if let keycode = keycodeForNamedKey(baseKey) {
                return PendingKeyEvent(keycode: keycode, mods: mods, label: normalized)
            }
            if baseKey.count == 1,
               let char = baseKey.first,
               let keycode = keycodeForLetter(char) {
                return PendingKeyEvent(keycode: keycode, mods: mods, label: normalized)
            }
            return nil
        }
    }

    @MainActor
    private func enqueuePendingSocketInput(_ input: PendingSocketInput) -> Bool {
        enqueuePendingSocketInputs([input])
    }

    @MainActor
    private func enqueuePendingSocketInputs(_ inputs: [PendingSocketInput]) -> Bool {
        let incomingBytes = inputs.reduce(0) { $0 + $1.estimatedBytes }
        guard incomingBytes > 0 else { return true }

        guard incomingBytes <= maxPendingSocketInputBytes,
              pendingSocketInputBytes + incomingBytes <= maxPendingSocketInputBytes else {
#if DEBUG
            cmuxDebugLog(
                "surface.socket_input.reject surface=\(id.uuidString.prefix(8)) " +
                "items=\(inputs.count) incomingBytes=\(incomingBytes) pendingBytes=\(pendingSocketInputBytes)"
            )
#endif
            return false
        }

        pendingSocketInputQueue.append(contentsOf: inputs)
        pendingSocketInputBytes += incomingBytes
#if DEBUG
        let pendingKeys = pendingSocketInputQueue.reduce(into: 0) { count, item in
            if case .key = item {
                count += 1
            }
        }
        cmuxDebugLog(
            "surface.socket_input.queue surface=\(id.uuidString.prefix(8)) items=\(pendingSocketInputQueue.count) " +
            "keys=\(pendingKeys) bytes=\(pendingSocketInputBytes)"
        )
#endif
        return true
    }

    @MainActor
    private func flushPendingSocketInputIfNeeded() {
        guard let surface = liveSurfaceForSocketWrite(reason: "socket.flushPendingInput") else { return }
        let queued = pendingSocketInputQueue
        let queuedBytes = pendingSocketInputBytes
        pendingSocketInputQueue.removeAll(keepingCapacity: false)
        pendingSocketInputBytes = 0
        guard !queued.isEmpty else { return }

        var queuedKeys = 0
        for item in queued {
            switch item {
            case .pasteText(let chunk):
                writeTextData(chunk, to: surface)
            case .inputText(let chunk):
                writeInputTextData(chunk, to: surface)
            case .processOutput(let chunk):
                writeProcessOutputData(chunk, to: surface)
            case .key(let event):
                queuedKeys += 1
                sendKeyEvent(surface: surface, keycode: event.keycode, mods: event.mods)
            }
        }
#if DEBUG
        cmuxDebugLog(
            "surface.socket_input.flush surface=\(id.uuidString.prefix(8)) items=\(queued.count) " +
            "keys=\(queuedKeys) bytes=\(queuedBytes)"
        )
#endif
    }

    func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    @discardableResult
    func toggleKeyboardCopyMode() -> Bool {
        let handled = surfaceView.toggleKeyboardCopyMode()
        if handled {
            setKeyboardCopyModeActive(surfaceView.isKeyboardCopyModeActive)
        }
        return handled
    }

    func setKeyboardCopyModeActive(_ active: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setKeyboardCopyModeActive(active)
            }
            return
        }

        if keyboardCopyModeActive != active {
            keyboardCopyModeActive = active
        }
        hostedView.syncKeyStateIndicator(text: surfaceView.currentKeyStateIndicatorText)
    }

    func hasSelection() -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

#if DEBUG
    @MainActor
    func setNeedsConfirmCloseOverrideForTesting(_ value: Bool?) {
        needsConfirmCloseOverrideForTesting = value
    }

    @MainActor
    func debugRuntimeSurfaceCreateAttemptCountForTesting() -> Int {
        runtimeSurfaceCreateAttemptCountForTesting
    }

    @MainActor
    func debugBackgroundSurfaceStartQueuedForTesting() -> Bool {
        backgroundSurfaceStartQueued
    }

    @MainActor
    func debugHasHeadlessStartupWindowForTesting() -> Bool {
        headlessStartupWindow != nil
    }

    @MainActor
    func debugPendingSocketInputForTesting() -> (
        items: Int,
        bytes: Int,
        keyEvents: Int,
        pasteTextItems: Int,
        inputTextItems: Int,
        processOutputItems: Int
    ) {
        let counts = pendingSocketInputQueue.reduce(
            into: (keyEvents: 0, pasteTextItems: 0, inputTextItems: 0, processOutputItems: 0)
        ) { counts, item in
            switch item {
            case .key:
                counts.keyEvents += 1
            case .pasteText:
                counts.pasteTextItems += 1
            case .inputText:
                counts.inputTextItems += 1
            case .processOutput:
                counts.processOutputItems += 1
            }
        }
        return (
            pendingSocketInputQueue.count,
            pendingSocketInputBytes,
            counts.keyEvents,
            counts.pasteTextItems,
            counts.inputTextItems,
            counts.processOutputItems
        )
    }

    /// Test-only helper to deterministically simulate a released runtime surface.
    @MainActor
    func releaseSurfaceForTesting() {
        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil

        guard let surfaceToFree = surface else {
            callbackContext?.release()
            return
        }

        TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        surface = nil
        ghostty_surface_free(surfaceToFree)
        callbackContext?.release()
    }

    /// Test-only helper to simulate a stale Swift wrapper whose native surface
    /// was already freed out-of-band.
    @MainActor
    func replaceSurfaceWithFreedPointerForTesting() {
        guard !runtimeSurfaceFreedOutOfBandForTesting else { return }

        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil

        guard let surfaceToFree = surface else {
            callbackContext?.release()
            return
        }

        TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        ghostty_surface_free(surfaceToFree)
        runtimeSurfaceFreedOutOfBandForTesting = true
        callbackContext?.release()
    }

    @MainActor
    func installRuntimeSurfaceForTesting(_ runtimeSurface: ghostty_surface_t) {
        surface = runtimeSurface
        portalLifecycleState = .live
        runtimeSurfaceFreedOutOfBandForTesting = false
    }
#endif

    deinit {
        claudeCommandShimInstallTask?.cancel()
        TerminalSurfaceRegistry.shared.unregister(self)
        markPortalLifecycleClosed(reason: "deinit")
        closeHeadlessStartupWindowIfNeeded()

        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil

        // Mirror teardownSurface/suspend: release the retained mobile byte-tee
        // userdata and drop the per-surface tee state keyed by this surface id,
        // BEFORE freeing the surface. A terminal closed via deinit (not explicit
        // teardown) would otherwise leak the tee userdata and leave stale mobile
        // replay buffers keyed by the old id. If teardown already ran, it nil'd
        // mobileByteTeeContext, so teeContext is nil here and ?.release() no-ops.
        let teeContext = mobileByteTeeContext
        mobileByteTeeContext = nil
        // `dropSurface` is @MainActor but `deinit` is nonisolated, so hop to the
        // main actor with the surface id captured by value (no self capture).
        // Dropping by id only clears the registry/replay state; releasing
        // `teeContext` on each exit path frees the userdata independently.
        let teeSurfaceID = id
        Task { @MainActor in MobileTerminalByteTee.shared.dropSurface(surfaceID: teeSurfaceID) }

        // Nil out the surface pointer so any in-flight closures (e.g. geometry
        // reconcile dispatched via DispatchQueue.main.async) that read self.surface
        // before this object is fully deallocated will see nil and bail out,
        // rather than passing a freed pointer to ghostty_surface_refresh (#432).
        let surfaceToFree = surface
        if let surfaceToFree {
            TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        }
        surface = nil

        guard let surfaceToFree else {
#if DEBUG
            cmuxDebugLog(
                "surface.lifecycle.deinit.skip surface=\(id.uuidString.prefix(5)) " +
                "workspace=\(tabId.uuidString.prefix(5)) reason=noRuntimeSurface"
            )
#endif
            callbackContext?.release()
            teeContext?.release()
            return
        }

#if DEBUG
        if runtimeSurfaceFreedOutOfBandForTesting {
            runtimeSurfaceFreedOutOfBandForTesting = false
            callbackContext?.release()
            teeContext?.release()
            return
        }
#endif

#if DEBUG
        cmuxDebugLog(
            "surface.lifecycle.deinit.begin surface=\(id.uuidString.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5)) hasAttachedView=\(attachedView != nil ? 1 : 0) " +
            "hostedInWindow=\(hostedView.window != nil ? 1 : 0)"
        )
#endif

        // Keep teardown asynchronous to avoid re-entrant close/deinit loops, but retain
        // callback userdata until surface free completes so callbacks never dereference
        // a deallocated view pointer.
        enqueueTerminalSurfaceRuntimeTeardown(
            id: id,
            workspaceId: tabId,
            reason: "deinit",
            surface: surfaceToFree,
            callbackContext: callbackContext
        )
        // The teardown coordinator releases callbackContext; teeContext is not
        // transported through the request, so release it here (mirrors teardownSurface).
        teeContext?.release()
    }
}

extension TerminalSurface {
    @MainActor
    func owningWorkspace() -> Workspace? {
        AppDelegate.shared?.workspaceFor(tabId: tabId)
    }
}
