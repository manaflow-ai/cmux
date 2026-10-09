public import CmuxNextSettings

/// `agentPane.showContextUsage` (``AgentPaneComposerSetting``) reaches the page as the `composer`
/// event, read by the page's composerSettings.ts.
extension AgentPageEvent {
    /// The composer's settings: `{showContextUsage}`.
    public static func composer(_ setting: AgentPaneComposerSetting) -> AgentPageEvent {
        AgentPageEvent(kind: "composer", value: setting.pageValue)
    }
}

/// Pushes the composer's settings to a pane's page. Kept off ``AgentPaneView``, whose type is at
/// its size limit; the value lives on the pane's model, where a new page subscriber reads it.
public enum AgentPaneComposerPush {
    /// Gives `view`'s page `setting` (a change only).
    @MainActor public static func apply(_ setting: AgentPaneComposerSetting, to view: AgentPaneView) {
        guard setting != view.model.composer else { return }
        view.model.composer = setting
        view.deliver([.composer(setting)], scripts: [script(setting)])
    }

    /// The script that gives a loaded old-host page the composer's settings.
    static func script(_ setting: AgentPaneComposerSetting) -> String {
        "window.cmuxAcpmuxComposer?.(\(setting.pageValue.compactText));"
    }
}
