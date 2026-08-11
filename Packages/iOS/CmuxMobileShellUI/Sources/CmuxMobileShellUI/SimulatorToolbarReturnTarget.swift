enum SimulatorToolbarReturnTarget: Equatable {
    case terminal(String)
    case browserStream(String)
    case simulator(String)
    case localBrowser

    static func resolve(
        preferred: Self?,
        terminalIDs: [String],
        browserStreamPanelIDs: [String],
        otherSimulatorPanelIDs: [String]
    ) -> Self? {
        switch preferred {
        case let .terminal(id) where terminalIDs.contains(id):
            return .terminal(id)
        case let .browserStream(id) where browserStreamPanelIDs.contains(id):
            return .browserStream(id)
        case let .simulator(id) where otherSimulatorPanelIDs.contains(id):
            return .simulator(id)
        case .localBrowser:
            return .localBrowser
        default:
            return terminalIDs.first.map(Self.terminal)
                ?? browserStreamPanelIDs.first.map(Self.browserStream)
                ?? otherSimulatorPanelIDs.first.map(Self.simulator)
        }
    }
}
