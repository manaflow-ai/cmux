public import SwiftUI
public import CmuxSubrouter

/// The live agent-session → account pinning list. Receives value snapshots
/// only.
public struct SubrouterSessionsSectionView: View {
    /// Long-lived daemons accumulate hundreds of session pins; the panel
    /// shows only the most recently routed handful.
    static let visibleSessionLimit = 8
    /// Pins older than this are routing history, not live sessions — they
    /// carry no actionable signal, so they only count toward the summary
    /// line. When nothing is recent the whole section disappears.
    static let recencyWindow: TimeInterval = 48 * 3600

    private let sessions: [SubrouterSessionAssignment]

    /// Creates the section.
    /// - Parameter sessions: The session snapshots, in daemon order.
    public init(sessions: [SubrouterSessionAssignment]) {
        self.sessions = sessions
    }

    public var body: some View {
        let recent = recentSessions
        if recent.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "subrouter.sessions.header", defaultValue: "Sessions"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(recent) { session in
                    SubrouterSessionRowView(session: session)
                }
                if sessions.count > recent.count {
                    Text(String(
                        localized: "subrouter.sessions.older",
                        defaultValue: "and \(sessions.count - recent.count) older"
                    ))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var recentSessions: [SubrouterSessionAssignment] {
        let cutoff = Date(timeIntervalSinceNow: -Self.recencyWindow)
        return sessions
            .filter { $0.updatedAt >= cutoff }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.visibleSessionLimit)
            .map { $0 }
    }
}

/// One session pin row: agent type, truncated session id, pinned account,
/// and last-routed time.
struct SubrouterSessionRowView: View {
    let session: SubrouterSessionAssignment

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(session.agentType)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                Text(String(session.sessionID.prefix(12)))
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(session.updatedAt, format: .relative(presentation: .named))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Text(String(
                localized: "subrouter.sessions.pinnedTo",
                defaultValue: "→ \(session.accountID)"
            ))
            .font(.system(size: 10))
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}
