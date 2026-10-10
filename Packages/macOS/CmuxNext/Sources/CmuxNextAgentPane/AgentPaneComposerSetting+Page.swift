public import CmuxNextSettings

/// `agentPane.showContextUsage` (``AgentPaneComposerSetting``) reaches the page as the `composer`
/// event, read by the page's composerSettings.ts.
extension AgentPageEvent {
    /// The composer's settings: `{showContextUsage, design}`.
    public static func composer(_ setting: AgentPaneComposerSetting) -> AgentPageEvent {
        AgentPageEvent(kind: "composer", value: setting.pageValue)
    }
}

/// Pushing to a pane's page lives here, off ``AgentPaneView``, whose type is at its size limit;
/// the pane's model keeps the value a new page subscriber reads.
extension AgentPaneComposerSetting {
    /// Gives `view`'s page these settings (a change only).
    @MainActor public func push(to view: AgentPaneView) {
        guard self != view.model.composer else { return }
        view.model.composer = self
        view.deliver([.composer(self)], scripts: [pageScript])
    }

    /// The script that gives a loaded old-host page the composer's settings.
    var pageScript: String { "window.cmuxAcpmuxComposer?.(\(pageValue.compactText));" }
}
