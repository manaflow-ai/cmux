import AppKit
import CmuxSidebar
import Foundation

/// `AppDelegate`'s conformance to the right-sidebar remote seam plus the thin
/// forwarding entry point. The interpreter logic lives in `CmuxSidebar`; this
/// file keeps window resolution, `FileExplorerState`, and the app-localized
/// failure strings app-side.
extension AppDelegate: RightSidebarRemoteHosting {
    /// Forwards a decoded remote command to the package interpreter, injecting
    /// the live host and the app-localized failure messages.
    func applyRightSidebarRemoteCommand(
        _ command: RightSidebarRemoteCommand,
        target: RightSidebarRemoteTarget = RightSidebarRemoteTarget()
    ) -> RightSidebarRemoteApplyResult {
        command.apply(
            target: target,
            host: self,
            strings: Self.rightSidebarRemoteStrings
        )
    }

    func rightSidebarRemoteResolution(
        for target: RightSidebarRemoteTarget
    ) -> RightSidebarRemoteResolution {
        let context = rightSidebarRemoteContext(target: target)
        let state: FileExplorerState?
        if target.isActiveTarget {
            state = context.flatMap { fileExplorerState(for: $0) } ?? fileExplorerState
        } else {
            state = context.flatMap { fileExplorerState(for: $0) }
        }
        let preferredWindow = context.flatMap { $0.window ?? windowForMainWindowId($0.windowId) }
        return RightSidebarRemoteResolution(
            contextExists: context != nil,
            preferredWindowExists: preferredWindow != nil,
            session: state.map { resolvedState in
                RightSidebarRemoteHostSession(
                    context: context,
                    state: resolvedState,
                    preferredWindow: preferredWindow,
                    host: self
                )
            }
        )
    }

    func isRightSidebarModeAvailable(_ mode: RightSidebarMode) -> Bool {
        mode.isAvailable()
    }

    private func rightSidebarRemoteContext(target: RightSidebarRemoteTarget) -> RegisteredMainWindow? {
        if let windowId = target.windowId {
            return registeredMainWindow(forWindowId: windowId)
        }
        if let workspaceId = target.workspaceId {
            return registeredMainWindows.first { context in
                context.tabManager.tabs.contains(where: { $0.id == workspaceId })
            }
        }
        return preferredRegisteredMainWindowContext()
    }

    /// App-localized failure messages handed to the interpreter. Resolved with
    /// `String(localized:)` so they bind to the app bundle's catalog (the
    /// package bundle lacks these keys).
    private static var rightSidebarRemoteStrings: RightSidebarRemoteStrings {
        RightSidebarRemoteStrings(
            targetNotFound: String(localized: "rightSidebar.remote.error.targetNotFound", defaultValue: "ERROR: Right sidebar target not found"),
            stateUnavailable: String(localized: "rightSidebar.remote.error.stateUnavailable", defaultValue: "ERROR: Right sidebar state not available"),
            unavailable: String(localized: "rightSidebar.remote.error.unavailable", defaultValue: "ERROR: Right sidebar not available"),
            focusFailed: String(localized: "rightSidebar.remote.error.focusFailed", defaultValue: "ERROR: Failed to focus right sidebar"),
            modeUnavailable: { mode in
                String(localized: "rightSidebar.remote.error.modeUnavailable", defaultValue: "ERROR: Right sidebar mode '\(mode.rawValue)' is not available")
            }
        )
    }
}
