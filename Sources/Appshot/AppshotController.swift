import AppKit

/// Orchestrates the "Appshot" feature: a system-wide hotkey captures the
/// frontmost macOS window (screenshot + Accessibility text) and routes it into
/// the active agent surface as context.
///
/// The capture itself runs off the main actor; recency state and delivery stay
/// on the main actor. Pure message formatting and the recency decision live in
/// ``AppshotModel`` so they can be unit-tested without screen capture.
@MainActor
final class AppshotController {
    static let shared = AppshotController()

    private var routingState = AppshotRoutingState()
    private var resignObserver: NSObjectProtocol?
    /// Guards against overlapping captures when the hotkey is held/repeated.
    private var isCapturing = false

    private init() {}

    /// Installs the app-active observer. Idempotent; called once at launch.
    func start() {
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.snapshotInteractiveAgentOnResign()
            }
        }
    }

    /// Snapshots the agent surface the user had focused at the moment cmux lost
    /// focus — the "I was just working with this agent" signal that the
    /// 60-second recency rule keys off of.
    private func snapshotInteractiveAgentOnResign() {
        guard let ref = AppDelegate.shared?.appshotFocusedAgentRef() else { return }
        routingState.lastInteractiveAgent = AppshotAgentRef(
            workspaceId: ref.workspaceId,
            panelId: ref.panelId,
            at: Date()
        )
    }

    /// Entry point invoked by the global hotkey (and reusable by other
    /// entrypoints). Captures off-main, then delivers on the main actor.
    func triggerFromGlobalHotkey() {
        guard !isCapturing else { return }
        isCapturing = true

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let frontApp = NSWorkspace.shared.frontmostApplication
        let pid = frontApp?.processIdentifier ?? 0
        let appName = frontApp?.localizedName
            ?? String(localized: "appshot.unknownApp", defaultValue: "Application")

        Task { @MainActor in
            let capture = await AppshotCapturer.capture(frontPID: pid, appName: appName, scale: scale)
            self.isCapturing = false
            if let capture, capture.promptText() != nil {
                self.deliver(capture)
            } else {
                AppshotPermissions.presentMissingPermissionsPromptIfNeeded()
            }
        }
    }

    private func deliver(_ capture: AppshotCapture) {
        guard let prompt = capture.promptText() else {
            NSSound.beep()
            return
        }
        let now = Date()

        // While cmux is frontmost the focused agent is, by definition, the agent
        // the user is interacting with right now. Persist it (not just a local
        // copy) so a later appshot routes to the agent that actually received
        // this one, even if no resign-active snapshot has fired since.
        if NSApp.isActive, let ref = AppDelegate.shared?.appshotFocusedAgentRef() {
            routingState.lastInteractiveAgent = AppshotAgentRef(
                workspaceId: ref.workspaceId,
                panelId: ref.panelId,
                at: now
            )
        }

        let state = routingState
        let lastRouteSurfaceExists = state.lastRoute.map {
            AppDelegate.shared?.appshotSurfaceExists(workspaceId: $0.workspaceId, panelId: $0.panelId) ?? false
        } ?? false
        let lastInteractiveSurfaceExists = state.lastInteractiveAgent.map {
            AppDelegate.shared?.appshotSurfaceExists(workspaceId: $0.workspaceId, panelId: $0.panelId) ?? false
        } ?? false

        let route = state.resolvedRoute(
            now: now,
            lastRouteSurfaceExists: lastRouteSurfaceExists,
            lastInteractiveSurfaceExists: lastInteractiveSurfaceExists
        )

        switch route {
        case let .append(workspaceId, panelId):
            if AppDelegate.shared?.sendAppshotText(prompt, workspaceId: workspaceId, panelId: panelId) == true {
                routingState.lastRoute = AppshotAgentRef(workspaceId: workspaceId, panelId: panelId, at: now)
            } else {
                openNewThread(with: prompt, now: now)
            }
        case .newThread:
            openNewThread(with: prompt, now: now)
        }
    }

    private func openNewThread(with prompt: String, now: Date) {
        if let ref = AppDelegate.shared?.openAppshotInNewWorkspace(prompt) {
            routingState.lastRoute = AppshotAgentRef(workspaceId: ref.workspaceId, panelId: ref.panelId, at: now)
        } else {
            NSSound.beep()
        }
    }
}
