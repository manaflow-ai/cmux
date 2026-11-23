import CmuxNextSettings

/// Settings > Advanced > Experiments (`experiments.*`, CmuxConfigSnapshot.experimentSwitches) reaches
/// the page as one object, `{"glassToolbarGroups": true, ...}`: the `experiments` event, read by the
/// page's experiments/switches.ts. The model keeps it for a page that loads again.
extension AgentPageEvent {
    public static func experiments(_ switches: [String: Bool]) -> AgentPageEvent {
        AgentPageEvent(kind: "experiments", value: .object(switches.mapValues(JSONValue.bool)))
    }

    /// The old host's script for the same push.
    var experimentsScript: String { "window.cmuxAcpmuxBridge?.applyExperiments?.(\(value.compactText));" }
}

extension AgentPaneView {
    /// Gives the page the Experiments switches (a change only).
    public func pushExperiments(_ switches: [String: Bool]) {
        guard switches != model.experiments else { return }
        model.experiments = switches
        replayExperiments()
    }

    /// Gives a new document (load, handshake) the switches it has none of.
    func replayExperiments() {
        let event = AgentPageEvent.experiments(model.experiments)
        deliver([event], scripts: [event.experimentsScript])
    }
}
