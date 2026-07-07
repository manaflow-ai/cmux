public import Foundation
public import CmuxWindowing

/// Routes the window-level **new-workspace / new-browser / cloud-VM creation
/// actions** over the cross-window window graph, owning the routing *decision
/// logic* while inverting every app effect through
/// ``WorkspaceCreationActionHosting``.
///
/// This is the package home for the legacy `AppDelegate`
/// `performNewWorkspaceAction` / `performNewBrowserWorkspaceAction` /
/// `performNewWorkspaceCreationAction` / `performCloudVMAction` bodies and their
/// private helpers (`workspaceGroupNewWorkspaceTarget`,
/// `closeInitialWorkspaceIfNeeded`, the in-group placement resolution). The
/// coordinator decides which window to route to (live-preferred, no-window
/// fallback, creation-preferred), the gate ordering between the remote-tmux
/// short-circuit, the configured-new-workspace override, the in-group create,
/// the preferred-`TabManager` path, and the new-window fallback, and the
/// close-initial-workspace condition. Each concrete reach into the
/// `MainWindowContext` aggregate, the config store, the configured-action
/// executor, the remote-tmux controller, and the cloud-VM launcher inverts
/// through the host.
///
/// **Window identity is an opaque ``CmuxWindowing/WindowID`` token.** The
/// coordinator never names `MainWindowContext`, `NSWindow`, `NSEvent`,
/// `TabManager`, or `Workspace`. The per-call app inputs (`preferredTabManager`,
/// `event`, `preferredWindow`) live behind the host's opaque
/// ``WorkspaceCreationActionHosting/SelectionContext``.
///
/// **Why synchronous and `@MainActor`.** Each action is one main-actor turn over
/// the main-actor window graph; co-locating on the main actor removes any
/// bridging (mirrors the sibling workspace coordinators' isolation ruling).
@MainActor
public final class WorkspaceCreationActionCoordinator<Host: WorkspaceCreationActionHosting> {
    private let host: Host

    /// Creates the coordinator over the app-side action host (the single
    /// conformer is `AppDelegate`). Constructor-injected, matching the sibling
    /// workspace coordinators.
    public init(host: Host) {
        self.host = host
    }

    // MARK: - New-workspace / new-browser entrypoints

    /// Creates a new terminal-initial workspace, routing to the right window
    /// (legacy `AppDelegate.performNewWorkspaceAction`).
    @discardableResult
    public func performNewWorkspaceAction(
        selector: Host.SelectionContext,
        debugSource: String
    ) -> Bool {
        performNewWorkspaceCreationAction(
            initialSurface: .terminal,
            selector: selector,
            debugSource: debugSource
        )
    }

    /// Creates a new workspace whose initial surface is a browser pane in its
    /// default new-tab state with the address bar focused. Shares the window
    /// routing, placement, and naming semantics of ``performNewWorkspaceAction``
    /// (legacy `AppDelegate.performNewBrowserWorkspaceAction`).
    @discardableResult
    public func performNewBrowserWorkspaceAction(
        selector: Host.SelectionContext,
        debugSource: String
    ) -> Bool {
        guard host.isBrowserEnabled else {
            // Legacy emitted the DEBUG `blocked_browser_disabled` line then beeped.
            host.beepBrowserDisabled(source: debugSource)
            return false
        }
        return performNewWorkspaceCreationAction(
            initialSurface: .browser,
            selector: selector,
            debugSource: debugSource
        )
    }

    @discardableResult
    private func performNewWorkspaceCreationAction(
        initialSurface: NewWorkspaceInitialSurface,
        selector: Host.SelectionContext,
        debugSource: String
    ) -> Bool {
        let livePreferredWindow = host.livePreferredWindowToken(for: selector)

        if host.hasNoMainWindows && livePreferredWindow == nil {
            host.logFallbackNewWindow(
                selector: selector,
                source: debugSource,
                reason: "no_main_windows"
            )
            let windowToken = host.createMainWindowToken()
            let initialWorkspaceId = host.selectedWorkspaceId(in: windowToken)
            switch initialSurface {
            case .terminal:
                _ = host.executeConfiguredNewWorkspaceActionIfAvailable(
                    in: windowToken,
                    debugSource: debugSource,
                    replacingInitialWorkspaceId: initialWorkspaceId,
                    target: nil
                )
            case .browser, .cloudVMLoading:
                // The fresh window boots with a terminal workspace; add the
                // requested workspace and close that initial one so the action's
                // result matches the no-window case for terminals.
                if let workspaceId = host.addWorkspace(in: windowToken, initialSurface: initialSurface) {
                    closeInitialWorkspaceIfNeeded(
                        initialWorkspaceId: initialWorkspaceId,
                        in: windowToken
                    )
                    if initialSurface == .browser {
                        host.focusInitialBrowserAddressBar(workspaceId: workspaceId)
                    }
                }
            }
            return true
        }

        let windowToken = livePreferredWindow
            ?? host.preferredWindowTokenForCreation(selector: selector, debugSource: debugSource)

        // In a dedicated remote-tmux window, a new workspace means "create a new
        // tmux session on that host" — route it to the remote and mirror it into
        // this window instead of creating a local workspace.
        if let windowToken,
           host.handleRemoteWindowNewWorkspaceRequested(in: windowToken) {
            return true
        }

        let target = windowToken.flatMap { workspaceGroupNewWorkspaceTarget(in: $0) }
        // The configured new-workspace action is the user's override for the
        // plain New Workspace behavior; the browser variant keeps its own fixed
        // semantics and skips it.
        if initialSurface == .terminal,
           let windowToken,
           host.executeConfiguredNewWorkspaceActionIfAvailable(
               in: windowToken,
               debugSource: debugSource,
               replacingInitialWorkspaceId: nil,
               target: target
           ) {
            return true
        }

        if let windowToken, let target {
            guard let workspaceId = host.createWorkspaceInGroup(
                in: windowToken,
                target: target,
                initialSurface: initialSurface
            ) else {
                return false
            }
            if initialSurface == .browser {
                host.focusInitialBrowserAddressBar(workspaceId: workspaceId)
            }
            return true
        }

        // Legacy: `if let preferredTabManager, preferredContext == nil ||
        // livePreferredContext != nil` — there is a preferred manager AND either
        // it is not tracked as a main-window context, or that context is live.
        if host.hasPreferredTabManager(selector: selector),
           host.preferredTabManagerHasNoMainWindowContext(selector: selector)
            || livePreferredWindow != nil {
            if let workspaceId = host.addWorkspaceToPreferredTabManager(
                selector: selector,
                initialSurface: initialSurface
            ), initialSurface == .browser {
                host.focusInitialBrowserAddressBar(workspaceId: workspaceId)
            }
            return true
        }

        if let workspaceId = host.addWorkspaceInPreferredMainWindow(
            selector: selector,
            initialSurface: initialSurface,
            debugSource: debugSource
        ) {
            if initialSurface == .browser {
                host.focusInitialBrowserAddressBar(workspaceId: workspaceId)
            }
        } else {
            host.logFallbackNewWindow(
                selector: selector,
                source: debugSource,
                reason: "workspace_creation_returned_nil"
            )
            host.openNewMainWindow()
        }
        return true
    }

    // MARK: - Cloud VM

    /// Launches a cloud VM creation against the routed window's socket (legacy
    /// `AppDelegate.performCloudVMAction`).
    @discardableResult
    public func performCloudVMAction(
        selector: Host.SelectionContext,
        debugSource: String,
        onCompletion: ((CloudVMActionCompletion) -> Void)?
    ) -> Bool {
        guard let windowToken = host.windowTokenForCloudVM(
            selector: selector,
            debugSource: debugSource
        ) else {
            host.beep()
            return false
        }
        return host.startCloudVM(
            in: windowToken,
            selector: selector,
            onCompletion: onCompletion
        )
    }

    // MARK: - In-group target resolution

    /// The resolved in-group new-workspace destination for `windowToken`'s
    /// selected workspace, or `nil` when it is not grouped (legacy
    /// `AppDelegate.workspaceGroupNewWorkspaceTarget(in:)`). The group lookup +
    /// anchor cwd read inverts through the host; the placement resolution
    /// (configured override, else stored default) and the target construction
    /// live here.
    public func workspaceGroupNewWorkspaceTarget(
        in windowToken: WindowID
    ) -> WorkspaceGroupNewWorkspaceTarget? {
        guard let membership = host.selectedWorkspaceGroupMembership(in: windowToken) else {
            return nil
        }
        let configured = host.configuredWorkspaceGroupNewPlacement(
            in: windowToken,
            anchorCwd: membership.anchorCwd
        )
        return WorkspaceGroupNewWorkspaceTarget(
            groupId: membership.groupId,
            referenceWorkspaceId: membership.selectedWorkspaceId,
            placement: configured ?? host.defaultWorkspaceGroupNewPlacement
        )
    }

    // MARK: - Close initial workspace

    /// Closes the initial workspace `initialWorkspaceId` in `windowToken` when it
    /// is no longer the selected one and other workspaces remain (legacy
    /// `AppDelegate.closeInitialWorkspaceIfNeeded`). The gating condition lives
    /// here; only the close inverts through the host.
    public func closeInitialWorkspaceIfNeeded(
        initialWorkspaceId: UUID?,
        in windowToken: WindowID?
    ) {
        guard let initialWorkspaceId,
              let windowToken,
              host.workspaceCount(in: windowToken) > 1,
              host.containsWorkspace(initialWorkspaceId, in: windowToken),
              host.selectedWorkspaceId(in: windowToken) != initialWorkspaceId else {
            return
        }
        host.closeWorkspace(initialWorkspaceId, in: windowToken)
    }
}
