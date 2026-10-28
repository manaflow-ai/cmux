import CmuxNextActions
import CmuxNextPalette

/// Only New Agent Chat's host argument uses the composer's agent destinations. Workspace
/// machine actions continue using their cmux-daemon inventory.
final class AgentChatTargetSource: PaletteTargetSource {
    private let destinations: AgentChatDestinations
    private let next: any PaletteTargetSource
    private var options: [PaletteTargetOption] = [Self.option(AgentChatDestinations.local)]

    init(destinations: AgentChatDestinations, next: any PaletteTargetSource) {
        (self.destinations, self.next) = (destinations, next)
    }

    private func owns(_ kind: ActionTargetKind, _ action: ActionID) -> Bool {
        kind == .machine && (action == "palette.newAgentChat" || action == "palette.newAgentChatOn")
    }

    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] { next.targets(of: kind) }
    func targets(of kind: ActionTargetKind, for action: ActionID) -> [PaletteTargetOption] {
        owns(kind, action) ? options : next.targets(of: kind, for: action)
    }
    func targetRefresh(of kind: ActionTargetKind, for action: ActionID) -> (@MainActor () async -> [PaletteTargetOption])? {
        guard owns(kind, action) else { return next.targetRefresh(of: kind, for: action) }
        return { [self] in
            let rows = await destinations.load()
            guard !Task.isCancelled else { return [] }
            options = rows.map(Self.option)
            return options
        }
    }
    func title(of target: ActionTargetRef) -> String? { next.title(of: target) }
    func currentDescription(of target: ActionTargetRef) -> String? { next.currentDescription(of: target) }

    private static func option(_ destination: AgentChatDestinations.Destination) -> PaletteTargetOption {
        PaletteTargetOption(id: destination.id, title: destination.title, subtitle: destination.state,
                            symbol: destination.symbol, isEnabled: destination.isReady)
    }
}
