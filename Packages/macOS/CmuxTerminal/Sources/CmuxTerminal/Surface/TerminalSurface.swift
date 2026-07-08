import Observation
public import AppKit
public import Combine
public import Foundation
public import GhosttyKit
public import CmuxTerminalCore
#if DEBUG
internal import CMUXDebugLog
#endif

/// The owner of one `ghostty_surface_t` lifecycle: spawn inputs, runtime
/// creation/teardown, pending input queues, portal-host leases, and renderer
/// reclamation state.
///
/// Lifted verbatim from `Sources/GhosttyTerminalView.swift`; the legacy
/// reach-ups into `GhosttyApp.shared` / `TerminalController.shared` /
/// `MobileTerminalByteTee.shared` / `RendererRealizationController.shared` /
/// `AgentHibernationController.shared` are inverted through the seams in
/// ``TerminalSurfaceRuntimeDependencies``.
///
/// Isolation: the model keeps the legacy main-thread-only contract. Members
/// that touch the native runtime or the hosted views are `@MainActor`;
/// stored properties are unannotated (the class itself is not `Sendable`, so
/// they never cross an isolation boundary) which keeps the nonisolated
/// `deinit` teardown path exactly as it was.
@Observable public final class TerminalSurface: Identifiable {
    /// The live find-in-terminal session state for one surface.
    @MainActor
    @Observable public final class SearchState {
        /// The current search needle.
        public var needle: String {
            didSet {
                guard needle != oldValue else { return }
                onNeedleChanged?(needle)
            }
        }

        /// The 1-based index of the selected match, if known.
        public var selected: UInt?

        /// The total number of matches, if known.
        public var total: UInt?

        @ObservationIgnored var onNeedleChanged: (@MainActor (String) -> Void)?

        /// Creates search state with an initial needle.
        public init(needle: String = "") {
            self.needle = needle
            self.selected = nil
            self.total = nil
        }
    }

    static let committedTextInputChunkByteLimit = 96

    /// `ESC[?7l`, disable DECAWM (autowrap). Injected around a mirror
    /// surface's resize to suppress ghostty primary-screen reflow.
    static let decawmDisableSequence = Data("\u{1b}[?7l".utf8)
    /// `ESC[?7h`, re-enable DECAWM after a mirror resize.
    static let decawmEnableSequence = Data("\u{1b}[?7h".utf8)

    // The surface value DTOs live in CmuxTerminalCore; these aliases keep the
    // nested TerminalSurface.NamedKeySendResult/.InputSendResult names that
    // other files use.
    public typealias NamedKeySendResult = CmuxTerminalCore.NamedKeySendResult
    public typealias InputSendResult = CmuxTerminalCore.InputSendResult
    public typealias ClaudeCommandShim = TerminalSurfaceClaudeCommandShim
    public typealias CodexCommandShim = TerminalSurfaceCodexCommandShim
    public typealias CmuxContextEnvironment = TerminalSurfaceCmuxContextEnvironment
    /// The live runtime surface pointer, or nil before creation/after teardown.
    @ObservationIgnored public internal(set) var surface: ghostty_surface_t?
    @ObservationIgnored weak var attachedView: (any TerminalSurfaceNativeViewing)?
    // MARK: Injected collaborators (see TerminalSurfaceRuntimeDependencies)
    let registry: any TerminalSurfaceRegistering
    let engine: any TerminalEngineHosting
    let spawnPolicyProvider: any TerminalSurfaceSpawnPolicyProviding
    let byteTee: any TerminalByteTeeBinding
    let rendererRealization: any TerminalRendererRealizationScheduling
    let hibernationRecorder: any AgentHibernationRecording
    let runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator
    let restoreSpawnScheduler: any TerminalSurfaceRuntimeSpawnScheduling
    let runtimeFilesystem: TerminalSurfaceRuntimeFilesystem
    /// Port ordinal base/range for CMUX_PORT assignment, snapshotted by the app composition root.
    let sessionPortBase: Int
    let sessionPortRangeSize: Int
    let scrollbackReplayEnvironmentKey: String
    let globalFontMagnificationPercent: @Sendable () -> Int

    /// cmux renderer reclamation: whether the current runtime surface's GPU
    /// renderer (Metal swap chain / IOSurface, ~40MB) is realized. A freshly
    /// created runtime surface is always realized, so this starts `true` and is
    /// reset to `true` in `createSurface`. `RendererRealizationController`
    /// releases it (`releaseRenderer`) while the surface is offscreen and idle;
    /// `setVisibleInUI(true)` re-realizes it (`realizeRenderer`) before the next
    /// draw. It mirrors Ghostty's swap-chain `defunct` flag so realize/unrealize
    /// strictly alternate (Ghostty's `displayRealized` asserts `defunct`).
    @ObservationIgnored var rendererRealized = true

    /// Wall-clock time (epoch seconds) this surface was last made visible in the
    /// UI. Used by `RendererRealizationController` as the LRU key so recently
    /// used tabs stay warm. Seeded at creation.
    public internal(set) var rendererLastVisibleAt: TimeInterval = Date().timeIntervalSince1970

    /// Authoritative on-screen flag, driven by `setVisibleInUI` (the same signal
    /// that drives Ghostty occlusion). The reclamation controller never releases
    /// a surface whose portal is visible.
    @ObservationIgnored var rendererPortalVisible = false

    /// Whether the runtime Ghostty surface exists and has not begun teardown.
    ///
    /// Use this as a quick availability check. Before passing `surface` to
    /// Ghostty C APIs that dereference the pointer (e.g.
    /// `ghostty_surface_inherited_config`, `ghostty_surface_quicklook_font`),
    /// call `liveSurfaceForGhosttyAccess(reason:)` so stale freed pointers are
    /// rejected and quarantined.
    public var hasLiveSurface: Bool { surface != nil && portalLifecycleState == .live }

    /// Whether the terminal surface view is currently attached to a window.
    ///
    /// Use the hosted view rather than the inner surface view, since the surface can be
    /// temporarily unattached (surface not yet created / reparenting) even while the panel
    /// is already in the window.
    @MainActor
    public var uiWindow: NSWindow? {
        guard let window = paneHost.window else { return nil }
        if let headlessStartupWindow, window === headlessStartupWindow {
            return nil
        }
        return window
    }

    /// Whether the surface's pane container is in a real (non-bootstrap) window.
    @MainActor
    public var isViewInWindow: Bool { uiWindow != nil }

    /// Whether `window` is this surface's hidden bootstrap startup window.
    public func isHeadlessStartupWindow(_ window: NSWindow?) -> Bool {
        guard let window, let headlessStartupWindow else { return false }
        return window === headlessStartupWindow
    }

    /// The stable identity of the terminal surface.
    public let id: UUID

    /// The owning workspace id.
    public private(set) var tabId: UUID

    /// Port ordinal for CMUX_PORT range assignment. Captured at construction so
    /// every runtime startup path uses the same immutable workspace port range.
    let portOrdinal: Int
    let surfaceContext: ghostty_surface_context_e
    let configTemplate: CmuxSurfaceConfigTemplate?
    let workingDirectory: String?

    /// The command to run instead of the default shell, if any.
    public let initialCommand: String?

    /// The tmux bootstrap command captured for respawn, if any.
    public let tmuxStartCommand: String?

    /// Text written to the surface immediately after the first spawn, if any.
    public let initialInput: String?
    @ObservationIgnored var nextRuntimeInitialInput: String?
    let initialEnvironmentOverrides: [String: String]

    /// The working directory requested at construction, if any.
    public var requestedWorkingDirectory: String? { workingDirectory }

    /// Where the surface participates in focus routing. Mutable so a live
    /// surface can move between the workspace area and the right-sidebar dock
    /// without being recreated (preserving its process). Always mutate through
    /// `setFocusPlacement(_:)` so the surface registry's placement record stays
    /// in sync. Reads happen on the main actor (UI/focus routing) and once on
    /// the creating thread at registration.
    public private(set) var focusPlacement: TerminalSurfaceFocusPlacement
    @ObservationIgnored var additionalEnvironment: [String: String]

    /// When true, the surface is created in libghostty MANUAL I/O mode: no
    /// process is spawned, output is injected via `processRemoteOutput(_:)`,
    /// and typed input is delivered to `manualInputHandler`.
    let manualIO: Bool
    let manualInputHandler: (@Sendable (Data) -> Void)?

    /// For MANUAL-I/O remote tmux display surfaces: invoked on the main actor
    /// whenever the rendered grid changes so the owner can size the remote tmux
    /// client to match.
    @MainActor public var onManualGridResize: (@MainActor (_ columns: Int, _ rows: Int) -> Void)?
    @ObservationIgnored var lastReportedManualGrid: (columns: Int, rows: Int)?
    /// For MANUAL-I/O remote tmux display surfaces: whether to suppress
    /// ghostty primary-screen reflow on resize.
    @ObservationIgnored var manualIONoReflow = true
    /// Retained userdata for the MANUAL-mode `io_write_cb`; released alongside
    /// the surface.
    @ObservationIgnored var manualIOContext: Unmanaged<TerminalManualIOWriteBox>?
    /// Output delivered before the runtime surface exists. Flushed once the
    /// surface is created so background mirror output is not lost.
    @ObservationIgnored var pendingRemoteOutput = Data()
    let maxPendingRemoteOutputBytes = 4 * 1_048_576

    /// The explicit startup environment overrides replayed on respawn.
    public var respawnInitialEnvironmentOverrides: [String: String] {
        initialEnvironmentOverrides
    }

    /// The additional environment replayed on respawn, with the one-shot
    /// scrollback-replay key stripped.
    public var respawnAdditionalEnvironment: [String: String] {
        var environment = additionalEnvironment
        environment.removeValue(forKey: scrollbackReplayEnvironmentKey)
        return environment
    }

    /// The pane container view hosting this surface (concrete view injected
    /// through ``TerminalSurfaceViewProviding``).
    public let paneHost: any TerminalSurfacePaneHosting
    let surfaceView: any TerminalSurfaceNativeViewing
    @ObservationIgnored var lastPixelWidth: UInt32 = 0
    @ObservationIgnored var lastPixelHeight: UInt32 = 0
    @ObservationIgnored var lastUncappedPixelWidth: UInt32 = 0
    @ObservationIgnored var lastUncappedPixelHeight: UInt32 = 0
    @ObservationIgnored var lastXScale: CGFloat = 0
    @ObservationIgnored var lastYScale: CGFloat = 0
    @ObservationIgnored var mobileViewportCellLimit: (columns: Int, rows: Int)?
    // Debug metadata is read from debug/CLI paths off the main thread; the
    // lock is the sanctioned carve-out for tiny values shared with
    // synchronous off-isolation readers.
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
    @ObservationIgnored var backgroundSurfaceStartSource: RuntimeSurfaceCreationSource = .normal
    @ObservationIgnored var paneHostAttachCreationSource: RuntimeSurfaceCreationSource = .normal
    @ObservationIgnored var restoredRuntimeSurfaceStartQueued = false
    @ObservationIgnored var requiresRestoreSpawnPacing = false
    @ObservationIgnored var runtimeSurfaceSuspendedForAgentHibernation = false
    @ObservationIgnored var headlessStartupWindow: NSWindow?
    @ObservationIgnored var surfaceCallbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
    @ObservationIgnored var claudeCommandShim: ClaudeCommandShim?
    @ObservationIgnored var claudeCommandShimInstallTask: Task<ClaudeCommandShim?, Never>?
    @ObservationIgnored var claudeCommandShimCompletionTask: Task<Void, Never>?
    @ObservationIgnored var claudeCommandShimInstallCompleted = false
    @ObservationIgnored var claudeCommandShimPendingCreationSource: RuntimeSurfaceCreationSource?
    /// The retained byte-tee lease for the libghostty PTY tee callback (cmux
    /// fork extension). Installed in `createSurface` after
    /// `ghostty_surface_new` succeeds; released alongside
    /// `surfaceCallbackContext` whenever we tear down or rebuild the
    /// surface. The Mac sync server reads the tee'd bytes to broadcast
    /// raw PTY output to paired iPhones (`MobileTerminalByteTee`).
    @ObservationIgnored var mobileByteTeeLease: (any TerminalByteTeeLease)?
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

    /// Bumped after every completed runtime clipboard read.
    public internal(set) var clipboardReadGeneration = 0
#if DEBUG
    @ObservationIgnored var needsConfirmCloseOverrideForTesting: Bool?
    @ObservationIgnored var runtimeSurfaceFreedOutOfBandForTesting = false
    @ObservationIgnored var runtimeSurfaceCreateAttemptCountForTesting = 0
    // Same off-isolation-reader carve-out as debugMetadataLock.
    let debugForceRefreshCountLock = NSLock()
    @ObservationIgnored var debugForceRefreshCountValue = 0
    /// Test-only override for the native free used by teardown paths.
    @MainActor
    public static var runtimeSurfaceFreeOverrideForTesting: (@Sendable (ghostty_surface_t) -> Void)?
#endif
    @ObservationIgnored var portalLifecycleState: PortalLifecycleState = .live
    @ObservationIgnored var portalLifecycleGeneration: UInt64 = 1
    @ObservationIgnored var activePortalHostLease: PortalHostLease?

    /// The live find session, or nil when find is closed. Setting it arms the
    /// debounced needle pipeline; clearing it ends the runtime search.
    /// Main-actor isolated: the observer cancels pane focus requests on the
    /// hosted view (the legacy didSet always ran on the main thread).
    @MainActor
    public var searchState: SearchState? = nil {
	        didSet {
            oldValue?.onNeedleChanged = nil
	            if let searchState {
	                paneHost.cancelFocusRequest()
#if DEBUG
                logDebugEvent("find.searchState created tab=\(tabId.uuidString.prefix(5)) surface=\(id.uuidString.prefix(5))")
#endif
                searchState.onNeedleChanged = { [weak self] needle in
                    self?.scheduleSearchNeedle(needle)
                }
                scheduleSearchNeedle(searchState.needle)
            } else if let oldValue {
                lastSearchNeedle = oldValue.needle
                searchNeedleTask?.cancel()
                searchNeedleTask = nil
#if DEBUG
                logDebugEvent("find.searchState cleared tab=\(tabId.uuidString.prefix(5)) surface=\(id.uuidString.prefix(5))")
#endif
                _ = performBindingAction("end_search")
            }
        }
    }

    /// Whether keyboard copy mode is active (mirrors the surface view).
    public internal(set) var keyboardCopyModeActive: Bool = false

    /// The needle from the most recently closed find session.
    public private(set) var lastSearchNeedle = ""
    @ObservationIgnored var searchNeedleTask: Task<Void, Never>?

    /// The key-state indicator text currently shown for the surface view.
    @MainActor
    public var currentKeyStateIndicatorText: String? { surfaceView.currentKeyStateIndicatorText }

    static func cmuxContextEnvironment(
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
    public func startupEnvironmentValue(_ key: String) -> String? {
        let socketPath = spawnPolicyProvider.controlSocketPath()
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

    /// Creates a surface model and its hosted view pair.
    ///
    /// Main-actor isolated (the legacy initializer asserted main-queue and
    /// hopped through `MainActor.assumeIsolated`; the isolation is now
    /// compiler-enforced).
    ///
    /// - Parameters mirror the legacy initializer, plus the injected
    ///   `dependencies` bundle constructed at the composition root.
    @MainActor
    public init(
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
        focusPlacement: TerminalSurfaceFocusPlacement = .workspace,
        manualIO: Bool = false,
        manualInputHandler: (@Sendable (Data) -> Void)? = nil,
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy = .immediate,
        dependencies: TerminalSurfaceRuntimeDependencies
    ) {
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
        self.manualIO = manualIO
        self.manualInputHandler = manualInputHandler
        self.registry = dependencies.registry
        self.engine = dependencies.engine
        self.spawnPolicyProvider = dependencies.spawnPolicy
        self.byteTee = dependencies.byteTee
        self.rendererRealization = dependencies.rendererRealization
        self.hibernationRecorder = dependencies.hibernationRecorder
        self.runtimeTeardown = dependencies.runtimeTeardown
        self.restoreSpawnScheduler = dependencies.restoreSpawnScheduler
        self.runtimeFilesystem = dependencies.runtimeFilesystem
        self.requiresRestoreSpawnPacing = runtimeSpawnPolicy == .pacedSessionRestore
        self.sessionPortBase = dependencies.sessionPortBase
        self.sessionPortRangeSize = dependencies.sessionPortRangeSize
        self.scrollbackReplayEnvironmentKey = dependencies.scrollbackReplayEnvironmentKey
        self.globalFontMagnificationPercent = dependencies.globalFontMagnificationPercent
        // Match Ghostty's own SurfaceView: ensure a non-zero initial frame so the backing layer
        // has non-zero bounds and the renderer can initialize without presenting a blank/stretched
        // intermediate frame on the first real resize.
        let views = dependencies.viewProvider.makeSurfaceViews(
            initialFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        self.surfaceView = views.surfaceView
        self.paneHost = views.paneHost
        registry.register(self)
        self.paneHost.attachSurface(self)

        let inheritedCommand = configTemplate?.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        let inheritedInput = configTemplate?.initialInput
        let hasStartupWork = self.initialCommand != nil
            || self.tmuxStartCommand != nil
            || trimmedInput != nil
            || inheritedCommand?.isEmpty == false
            || inheritedInput?.isEmpty == false
            // MANUAL-I/O remote-tmux display surfaces have no command but must
            // start eagerly so they can receive injected output while their
            // workspace is still in the background.
            || manualIO

        // Surfaces with startup work must spawn before the user focuses their workspace.
        // Ghostty's embedded surface creation still expects a view with a window, so use
        // a hidden bootstrap window until the real portal host is ready.
        if hasStartupWork {
            scheduleHeadlessRuntimeStartIfNeeded(reason: "startup")
        }
    }

    /// Whether the surface stays open after its startup command exits.
    public func debugWaitAfterCommand() -> Bool {
        configTemplate?.waitAfterCommand ?? false
    }

    /// The ghostty launch context the surface was created with.
    public var launchContext: ghostty_surface_context_e {
        surfaceContext
    }

    /// Rebinds the surface (and its views) to a new owning workspace id.
    @MainActor
    public func updateWorkspaceId(_ newTabId: UUID) {
        tabId = newTabId
        attachedView?.tabId = newTabId
        surfaceView.tabId = newTabId
    }

    /// Moves this surface between focus-routing placements (workspace ↔
    /// right-sidebar dock) and keeps the surface registry's record in sync.
    /// Used when a live terminal is dragged across containers so it is not
    /// recreated. No-op when the placement is unchanged.
    @MainActor
    public func setFocusPlacement(_ placement: TerminalSurfaceFocusPlacement) {
        guard focusPlacement != placement else { return }
        focusPlacement = placement
        registry.updateFocusPlacement(id: id, placement)
    }

    deinit {
        claudeCommandShimInstallTask?.cancel()
        claudeCommandShimCompletionTask?.cancel()
        registry.unregister(self)
        markPortalLifecycleClosed(reason: "deinit")
        // Mirror closeHeadlessStartupWindowIfNeeded: deinit is nonisolated, so
        // the NSWindow teardown hops to the main actor through the same kind of
        // @unchecked Sendable transport the runtime teardown request uses. The
        // legacy path closed synchronously when deinit happened to run on the
        // main thread; closing on the next main-actor turn is unobservable for
        // a hidden, alpha-zero bootstrap window.
        if let startupWindow = headlessStartupWindow {
            headlessStartupWindow = nil
            let closeRequest = TerminalSurfaceHeadlessWindowCloseRequest(window: startupWindow)
            Task { @MainActor in closeRequest.close() }
        }

        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil
        let manualIOContext = manualIOContext
        self.manualIOContext = nil

        // Mirror teardownSurface/suspend: release the retained mobile byte-tee
        // userdata and drop the per-surface tee state keyed by this surface id,
        // BEFORE freeing the surface. A terminal closed via deinit (not explicit
        // teardown) would otherwise leak the tee userdata and leave stale mobile
        // replay buffers keyed by the old id. If teardown already ran, it nil'd
        // mobileByteTeeLease, so teeLease is nil here and ?.release() no-ops.
        let teeLease = mobileByteTeeLease
        mobileByteTeeLease = nil
        // `dropSurface` is @MainActor but `deinit` is nonisolated, so hop to the
        // main actor with the surface id captured by value (no self capture).
        // Dropping by id only clears the registry/replay state; releasing
        // `teeLease` on each exit path frees the userdata independently.
        let teeSurfaceID = id
        let teeBinding = byteTee
        Task { @MainActor in teeBinding.dropSurface(surfaceID: teeSurfaceID) }

        // Nil out the surface pointer so any in-flight closures (e.g. geometry
        // reconcile dispatched via DispatchQueue.main.async) that read self.surface
        // before this object is fully deallocated will see nil and bail out,
        // rather than passing a freed pointer to ghostty_surface_refresh (#432).
        let surfaceToFree = surface
        if let surfaceToFree {
            registry.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        }
        surface = nil

        guard let surfaceToFree else {
#if DEBUG
            logDebugEvent(
                "surface.lifecycle.deinit.skip surface=\(id.uuidString.prefix(5)) " +
                "workspace=\(tabId.uuidString.prefix(5)) reason=noRuntimeSurface"
            )
#endif
            callbackContext?.release()
            manualIOContext?.release()
            teeLease?.release()
            return
        }

#if DEBUG
        if runtimeSurfaceFreedOutOfBandForTesting {
            runtimeSurfaceFreedOutOfBandForTesting = false
            callbackContext?.release()
            manualIOContext?.release()
            teeLease?.release()
            return
        }
#endif

#if DEBUG
        logDebugEvent(
            "surface.lifecycle.deinit.begin surface=\(id.uuidString.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5)) hasAttachedView=\(attachedView != nil ? 1 : 0)"
        )
#endif

        // Keep teardown asynchronous to avoid re-entrant close/deinit loops, but retain
        // callback userdata until surface free completes so callbacks never dereference
        // a deallocated view pointer.
        runtimeTeardown.enqueueRuntimeTeardown(
            id: id,
            workspaceId: tabId,
            reason: "deinit",
            surface: surfaceToFree,
            callbackContext: callbackContext
        )
        // The teardown coordinator releases callbackContext; manualIOContext and
        // teeLease are not transported through the request, so release them here.
        manualIOContext?.release()
        teeLease?.release()
    }
}

// The callback-context and registry seam conformances live with the model so
// every consumer of the package sees the same identity surface.
extension TerminalSurface: TerminalSurfaceControlling {
    /// The stable identity of the terminal surface (callback seam).
    public var surfaceId: UUID { id }

    /// The workspace tab that owns the surface (callback seam).
    public var owningTabId: UUID { tabId }

    /// The live runtime surface pointer (callback seam).
    public var runtimeSurfacePointer: ghostty_surface_t? { surface }
}

// The engine's surface registry tracks surfaces behind the cross-domain
// TerminalSurfacing seam; TerminalSurface satisfies it with its immutable
// `id` and `focusPlacement`.
extension TerminalSurface: TerminalSurfacing {}

/// Transports the hidden bootstrap window from a nonisolated `deinit` to the
/// main actor for closing. `@unchecked Sendable` because the window is
/// exclusively owned by the request from creation until `close()` runs.
private struct TerminalSurfaceHeadlessWindowCloseRequest: @unchecked Sendable {
    let window: NSWindow

    @MainActor
    func close() {
        window.contentView = nil
        window.close()
    }
}
