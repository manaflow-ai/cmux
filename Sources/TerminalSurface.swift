import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import Observation
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


enum TerminalSurfaceFocusPlacement: Equatable {
    case workspace
    case rightSidebarDock
}

func recordAgentHibernationTerminalInput(workspaceId: UUID, panelId: UUID) {
    guard AgentHibernationTrackingGate.isEnabled() else { return }
    let recordedAt = Date()
    Task { @MainActor in
        AgentHibernationController.shared.recordTerminalInput(
            workspaceId: workspaceId,
            panelId: panelId,
            recordedAt: recordedAt
        )
    }
}

@Observable
final class TerminalSurface: Identifiable {
    @Observable
    final class SearchState {
        var needle: String {
            didSet { needleSubject.send(needle) }
        }
        var selected: UInt?
        var total: UInt?

        /// Combine mirror of `needle` feeding the find-debounce pipeline in
        /// `TerminalSurface.searchState`'s `didSet`. A `CurrentValueSubject`
        /// replays the current value on subscribe, matching the former
        /// `$needle` projection's initial emission.
        @ObservationIgnored private let needleSubject: CurrentValueSubject<String, Never>

        var needlePublisher: AnyPublisher<String, Never> {
            needleSubject.eraseToAnyPublisher()
        }

        init(needle: String = "") {
            self.needleSubject = CurrentValueSubject(needle)
            self.needle = needle
            self.selected = nil
            self.total = nil
        }
    }

    enum PendingSocketInput {
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

    // `@ObservationIgnored` below preserves the pre-`@Observable` contract:
    // only `searchState` and `keyboardCopyModeActive` were `@Published`, so
    // they stay the only observation-tracked properties. The rest are runtime
    // bookkeeping mutated from AppKit layout/portal attach (which runs inside
    // SwiftUI view updates), per-keystroke/socket hot paths, and `deinit`;
    // tracking them would add registrar work on those paths and risk
    // mid-update invalidation without any view depending on them.
    @ObservationIgnored var surface: ghostty_surface_t?
    @ObservationIgnored weak var attachedView: GhosttyNSView?

    let id: UUID
    @ObservationIgnored var tabId: UUID
    /// Port ordinal for CMUX_PORT range assignment. Captured at construction so
    /// every runtime startup path uses the same immutable workspace port range.
    let portOrdinal: Int
    /// Snapshotted once per app session so all workspaces use consistent values
    static let sessionPortBase: Int = {
        let val = UserDefaults.standard.integer(forKey: AutomationSettings.portBaseKey)
        return val > 0 ? val : AutomationSettings.defaultPortBase
    }()
    static let sessionPortRangeSize: Int = {
        let val = UserDefaults.standard.integer(forKey: AutomationSettings.portRangeKey)
        return val > 0 ? val : AutomationSettings.defaultPortRange
    }()
    let surfaceContext: ghostty_surface_context_e
    let configTemplate: CmuxSurfaceConfigTemplate?
    let workingDirectory: String?
    let initialCommand: String?
    let tmuxStartCommand: String?
    let initialInput: String?
    @ObservationIgnored var nextRuntimeInitialInput: String?
    let initialEnvironmentOverrides: [String: String]
    var requestedWorkingDirectory: String? { workingDirectory }
    let focusPlacement: TerminalSurfaceFocusPlacement
    @ObservationIgnored var additionalEnvironment: [String: String]
    var respawnInitialEnvironmentOverrides: [String: String] {
        initialEnvironmentOverrides
    }
    var respawnAdditionalEnvironment: [String: String] {
        var environment = additionalEnvironment
        environment.removeValue(forKey: SessionScrollbackReplayStore.environmentKey)
        return environment
    }
    let hostedView: GhosttySurfaceScrollView
    let surfaceView: GhosttyNSView
    @ObservationIgnored var lastPixelWidth: UInt32 = 0
    @ObservationIgnored var lastPixelHeight: UInt32 = 0
    @ObservationIgnored var lastUncappedPixelWidth: UInt32 = 0
    @ObservationIgnored var lastUncappedPixelHeight: UInt32 = 0
    @ObservationIgnored var lastXScale: CGFloat = 0
    @ObservationIgnored var lastYScale: CGFloat = 0
    @ObservationIgnored var mobileViewportCellLimit: (columns: Int, rows: Int)?
    let debugMetadataLock = NSLock()
    let createdAt: Date = Date()
    @ObservationIgnored var runtimeSurfaceCreatedAt: Date?
    @ObservationIgnored var teardownRequestedAt: Date?
    @ObservationIgnored var teardownRequestReason: String?
    // Main-thread only. Public socket send entrypoints are MainActor-isolated
    // before reading `surface` or mutating this pending queue.
    @ObservationIgnored var pendingSocketInputQueue: [PendingSocketInput] = []
    @ObservationIgnored var pendingSocketInputBytes: Int = 0
    let maxPendingSocketInputBytes = 1_048_576
    @ObservationIgnored var backgroundSurfaceStartQueued = false
    @ObservationIgnored var runtimeSurfaceSuspendedForAgentHibernation = false
    @ObservationIgnored var headlessStartupWindow: NSWindow?
    @ObservationIgnored var surfaceCallbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
    @ObservationIgnored var claudeCommandShim: ClaudeCommandShim?
    @ObservationIgnored var claudeCommandShimInstallTask: Task<ClaudeCommandShim?, Never>?
    @ObservationIgnored var claudeCommandShimInstallCompleted = false
    /// Heap-allocated userdata for the libghostty PTY tee callback (cmux
    /// fork extension). Installed in `createSurface` after
    /// `ghostty_surface_new` succeeds; released alongside
    /// `surfaceCallbackContext` whenever we tear down or rebuild the
    /// surface. The Mac sync server reads the tee'd bytes to broadcast
    /// raw PTY output to paired iPhones (`MobileTerminalByteTee`).
    @ObservationIgnored var mobileByteTeeContext: Unmanaged<MobileTerminalByteTeeUserdata>?
    /// The desired focus state for the Ghostty C surface. May be set before the
    /// C surface exists (e.g. during layout restoration); `createSurface`
    /// reapplies this value once the runtime surface exists, then keeps using it
    /// as a dedup guard to avoid redundant `ghostty_surface_set_focus` calls
    /// (prevents prompt redraws with P10k).
    ///
    /// Start unfocused and only opt into focus when the workspace/AppKit focus
    /// path explicitly requests it so background panes do not keep a focused
    /// state unless the workspace focus path requests it.
    @ObservationIgnored var desiredFocusState: Bool = false
    @ObservationIgnored private(set) var clipboardReadGeneration = 0
#if DEBUG
    @ObservationIgnored var needsConfirmCloseOverrideForTesting: Bool?
    @ObservationIgnored var runtimeSurfaceFreedOutOfBandForTesting = false
    @ObservationIgnored var runtimeSurfaceCreateAttemptCountForTesting = 0
    let debugForceRefreshCountLock = NSLock()
    @ObservationIgnored var debugForceRefreshCountValue = 0
    @MainActor
    static var runtimeSurfaceFreeOverrideForTesting: (@Sendable (ghostty_surface_t) -> Void)?
#endif
    enum PortalLifecycleState: String {
        case live
        case closing
        case closed
    }
    struct PortalHostLease {
        let hostId: ObjectIdentifier
        let paneId: UUID
        let instanceSerial: UInt64
        let inWindow: Bool
        let area: CGFloat
    }
    @ObservationIgnored var portalLifecycleState: PortalLifecycleState = .live
    @ObservationIgnored var portalLifecycleGeneration: UInt64 = 1
    @ObservationIgnored var activePortalHostLease: PortalHostLease?
    /// Fires on every `searchState` assignment with the new value. Replaces
    /// the former `$searchState` projection (`TerminalPanel` syncs its own
    /// `searchState` from it); subscribers needing the projection's
    /// initial-value emission `prepend(searchState)` at subscribe time.
    @ObservationIgnored let searchStateEdits = PassthroughSubject<SearchState?, Never>()
    var searchState: SearchState? = nil {
	        didSet {
	            // Mirror the former `$searchState` willSet-time publish before
	            // the handler logic below runs.
	            searchStateEdits.send(searchState)
	            if let searchState {
	                hostedView.cancelFocusRequest()
#if DEBUG
                cmuxDebugLog("find.searchState created tab=\(tabId.uuidString.prefix(5)) surface=\(id.uuidString.prefix(5))")
#endif
                searchNeedleCancellable = searchState.needlePublisher
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
    private(set) var keyboardCopyModeActive: Bool = false
    @ObservationIgnored private(set) var lastSearchNeedle = ""
    @ObservationIgnored private var searchNeedleCancellable: AnyCancellable?
    var currentKeyStateIndicatorText: String? { surfaceView.currentKeyStateIndicatorText }

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

    func noteClipboardReadCompleted() {
        clipboardReadGeneration += 1
        NotificationCenter.default.post(
            name: .terminalSurfaceDidCompleteClipboardRead,
            object: self
        )
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

// MARK: - Ghostty Surface View

