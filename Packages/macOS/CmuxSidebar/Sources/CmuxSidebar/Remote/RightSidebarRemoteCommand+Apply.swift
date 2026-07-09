import Foundation

extension RightSidebarRemoteCommand {
    /// Applies this `right_sidebar` remote command to the window addressed by
    /// `target`, against a live `host`.
    ///
    /// This is a faithful relocation of the former `AppDelegate`
    /// `applyRightSidebarRemoteCommand(_:target:)`. All live AppKit state
    /// (`FileExplorerState`, the registered window, the focus coordinator) stays
    /// app-side behind ``RightSidebarRemoteHosting`` /
    /// ``RightSidebarRemoteSession``; localized failure messages are injected via
    /// ``RightSidebarRemoteStrings``.
    @MainActor
    public func apply(
        target: RightSidebarRemoteTarget,
        host: any RightSidebarRemoteHosting,
        strings: RightSidebarRemoteStrings
    ) -> RightSidebarRemoteApplyResult {
        let resolution = host.rightSidebarRemoteResolution(for: target)
        if !target.isActiveTarget, !resolution.contextExists {
            return .failure(strings.targetNotFound)
        }
        guard let session = resolution.session else {
            return .failure(strings.stateUnavailable)
        }

        let requiresWindowFocus: Bool
        switch self {
        case .focus:
            requiresWindowFocus = true
        case .setMode(_, let focus):
            requiresWindowFocus = focus
        case .toggle, .show, .hide, .getState:
            requiresWindowFocus = false
        }
        if requiresWindowFocus, !target.isActiveTarget, !resolution.preferredWindowExists {
            return .failure(strings.targetNotFound)
        }

        switch self {
        case .toggle:
            guard target.isActiveTarget || resolution.preferredWindowExists else {
                return .failure(strings.targetNotFound)
            }
            guard session.toggle() else {
                return .failure(strings.unavailable)
            }
            return .ok

        case .show:
            guard !session.isVisible else {
                return .ok
            }
            guard target.isActiveTarget || resolution.preferredWindowExists else {
                return .failure(strings.targetNotFound)
            }
            guard session.toggle() else {
                return .failure(strings.unavailable)
            }
            return .ok

        case .hide:
            let wasVisible = session.isVisible
            session.setVisible(false)
            if wasVisible {
                session.restoreTerminalFocusIfNeeded()
            }
            return .ok

        case .focus:
            // Remote focus should preserve the currently selected sidebar mode
            // instead of reviving a stale keyboard-focus memory.
            guard session.focus(mode: session.mode) else {
                return .failure(strings.focusFailed)
            }
            return .ok

        case .setMode(let mode, let focus):
            guard host.isRightSidebarModeAvailable(mode) else {
                return .failure(strings.modeUnavailable(mode))
            }
            if focus {
                guard session.focus(mode: mode) else {
                    return .failure(strings.focusFailed)
                }
            } else {
                session.setVisible(true)
                session.setMode(mode)
                session.rememberMode(mode)
            }
            return .ok

        case .getState:
            return .state(.init(visible: session.isVisible, mode: session.mode))
        }
    }
}
