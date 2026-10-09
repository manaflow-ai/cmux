public import CmuxNextSettings

/// `agentPane.showContextUsage` (``AgentPaneComposerSetting``) reaches the page as the `composer`
/// event, read by the page's composerSettings.ts.
extension AgentPageEvent {
    /// The composer's settings: `{showContextUsage}`.
    public static func composer(_ setting: AgentPaneComposerSetting) -> AgentPageEvent {
        AgentPageEvent(kind: "composer", value: setting.pageValue)
    }
}

extension AgentPaneView {
    /// The script that gives a loaded old-host page the composer's settings.
    static func composerScript(_ setting: AgentPaneComposerSetting) -> String {
        "window.cmuxAcpmuxComposer?.(\(setting.pageValue.compactText));"
    }

    /// Pushes ``composer`` to the page.
    func applyComposer() {
        deliver([.composer(composer)], scripts: [Self.composerScript(composer)])
    }
}
