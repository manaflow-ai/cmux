import CmuxAgentBrands

nonisolated extension HistoryEntry {
    /// The brand mark an agent session's row draws (its provider's), or nil.
    public var agentBrand: String? {
        switch payload {
        case .agent(let session):
            return AgentBrandCatalog.brand(for: session.provider)?.rawValue
        case .closed(let item):
            return AgentBrandCatalog.brand(for: item.agentSession?.harness)?.rawValue
        default:
            return nil
        }
    }

    /// A row's second line: the entry's detail and its machine's name, or nil with neither.
    public var detailLine: String? {
        let line = [detail, machineName].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }
}

nonisolated extension HistoryEntry.Kind {
    /// The SF Symbol a row of this kind draws.
    public var symbol: String {
        switch self {
        case .page: "globe"
        case .location: "location"
        case .closed: "arrow.uturn.backward"
        case .command: "terminal"
        case .agent: "sparkles"
        }
    }
}
