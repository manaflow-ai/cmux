import SwiftUI

/// Where the user's Chief runs: the server, its state and its last reply.
struct ChiefPlacementRow: View {
    let status: ChiefPlacementStatus
    @Environment(\.serverColors) private var colors

    var body: some View {
        MetricRow(symbol: "brain", title: ServerStrings.chiefOn(status.serverName), value: value, dot: dot)
    }

    private var value: String {
        let reply = status.lastReply.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) }
        return [ServerStrings.state(status.state), reply ?? ServerStrings.noReplyYet].joined(separator: " · ")
    }

    private var dot: Color {
        switch status.state {
        case .ready: colors.ok
        case .thinking: colors.secondary
        case .notAnswering: colors.critical
        }
    }
}
