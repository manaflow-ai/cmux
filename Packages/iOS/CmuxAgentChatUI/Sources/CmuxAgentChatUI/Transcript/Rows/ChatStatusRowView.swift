import CmuxAgentChat
import SwiftUI

/// A centered caption for a durable session lifecycle transition
/// ("Session started", "Interrupted", ...).
public struct ChatStatusRowView: View {
    private let transition: ChatStatusTransition
    private let timestamp: Date

    /// Creates a status row.
    ///
    /// - Parameters:
    ///   - transition: The lifecycle transition payload.
    ///   - timestamp: When the transition occurred.
    public init(transition: ChatStatusTransition, timestamp: Date) {
        self.transition = transition
        self.timestamp = timestamp
    }

    public var body: some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }

    private var label: String {
        let base = eventLabel
        if let detail = transition.detail, !detail.isEmpty {
            return "\(base) · \(detail)"
        }
        return base
    }

    private var eventLabel: String {
        switch transition.event {
        case .sessionStarted:
            return String(
                localized: "chat.status.session_started",
                defaultValue: "Session started",
                bundle: .module
            )
        case .sessionEnded:
            return String(
                localized: "chat.status.session_ended",
                defaultValue: "Session ended",
                bundle: .module
            )
        case .interrupted:
            return String(
                localized: "chat.status.interrupted",
                defaultValue: "Interrupted",
                bundle: .module
            )
        case .contextCompacted:
            return String(
                localized: "chat.status.context_compacted",
                defaultValue: "Context compacted",
                bundle: .module
            )
        }
    }
}
