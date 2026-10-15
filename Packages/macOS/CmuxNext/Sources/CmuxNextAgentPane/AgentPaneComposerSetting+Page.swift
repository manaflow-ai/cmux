public import CmuxNextSettings

/// `agentPane.showContextUsage` and `agentPane.showDictation` (``AgentPaneComposerSetting``) reach
/// the page as the `composer` event, read by the page's composerSettings.ts. The event also carries
/// `plainFooter`, Debug Settings' plain footer look (``AgentPaneTunables/composerPlainFooter``),
/// which is no setting: it is read here, on the pane's side, each time the event is made.
extension AgentPageEvent {
    /// The composer's settings: `{showContextUsage, showDictation, plainFooter}`.
    public static func composer(_ setting: AgentPaneComposerSetting) -> AgentPageEvent {
        AgentPageEvent(kind: "composer", value: setting.pageValueWithLook)
    }
}

/// Pushing to a pane's page lives here, off ``AgentPaneView``, whose type is at its size limit;
/// the pane's model keeps the value a new page subscriber reads.
extension AgentPaneComposerSetting {
    /// Gives `view`'s page these settings (a change only), or, with `lookChanged`, again after
    /// Debug Settings' plain footer look changed.
    @MainActor public func push(to view: AgentPaneView, lookChanged: Bool = false) {
        guard lookChanged || self != view.model.composer else { return }
        view.model.composer = self
        view.deliver([.composer(self)], scripts: [pageScript])
    }

    /// The page's value with the plain footer look.
    var pageValueWithLook: JSONValue {
        var value = pageValue.objectValue ?? [:]
        value["plainFooter"] = .bool(AgentPaneTunables.composerPlainFooter.value)
        return .object(value)
    }

    /// The script that gives a loaded old-host page the composer's settings.
    var pageScript: String { "window.cmuxAcpmuxComposer?.(\(pageValueWithLook.compactText));" }
}
