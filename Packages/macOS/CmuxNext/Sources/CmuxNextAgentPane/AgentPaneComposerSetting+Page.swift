import CmuxNextCompat
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
    /// Gives `view`'s page these settings (a change only, or every page while Debug Settings' plain
    /// footer look changes).
    @MainActor public func push(to view: AgentPaneView) {
        guard Self.lookChanging || self != view.model.composer else { return }
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

    /// Debug Settings' plain footer look as the pages last got it, and whether its change is being
    /// pushed (``push(to:)`` then sends every page the event again).
    @MainActor private static var lookShown = false
    @MainActor private static var lookChanging = false
    @MainActor private static var lookObservation: Task<Void, Never>?

    /// Follows Debug Settings' plain footer look for the agent tabs: `push` (the tabs' push of their
    /// page settings to every view) runs on each change.
    @MainActor public static func followLook(_ push: @escaping () -> Void) {
        lookObservation?.cancel()
        // task-owner: lives as long as the agent tabs (one per app); event-driven (Observation)
        lookObservation = Task {
            for await on in ObservationStream({ AgentPaneTunables.composerPlainFooter.value }) {
                guard on != lookShown else { continue }
                lookShown = on
                lookChanging = true
                push()
                lookChanging = false
            }
        }
    }
}
