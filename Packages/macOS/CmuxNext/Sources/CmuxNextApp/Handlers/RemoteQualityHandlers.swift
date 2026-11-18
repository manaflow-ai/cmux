import CmuxNextActions
import CmuxNextRemoteView
import CmuxNextRemoteViewSessions

/// Set Screen Sharing Quality… (`remote.setQuality`): a remote desktop tab's quality preset. The
/// session toolbar's Quality menu runs this action on its own tab (`RemoteViewPageTab.onPickQuality`),
/// so the menu and the palette run one handler; the palette offers it while a remote desktop
/// session is the focused tab.
extension RemoteHandlers {
    static func bindQuality(into registry: ActionRegistry, context: AppActionContext) {
        registry.bindEffect("remote.setQuality", effect: { invocation in
            guard let page = remoteDesktop(invocation, context) else { return .refused(RemoteDesktopPane.noSessionReason) }
            guard let preset = invocation["quality"]?.stringValue.flatMap(RemoteQualityPreset.init(rawValue:)) else { return .done }
            page.selectQuality(preset)
            return .done
        })
        ActionTargetVisibility.gate("remote.setQuality", in: registry) { remoteDesktop($0, context) == nil ? RemoteDesktopPane.noSessionReason : nil }
    }

    /// The invocation's tab (the toolbar's own), else the focused pane's, when it streams a remote desktop session.
    static func remoteDesktop(_ invocation: ActionInvocation, _ context: AppActionContext) -> RemoteViewPageTab? {
        guard let page = (try? context.page(invocation))?.tab as? RemoteViewPageTab, page.streams else { return nil }
        return page
    }
}
