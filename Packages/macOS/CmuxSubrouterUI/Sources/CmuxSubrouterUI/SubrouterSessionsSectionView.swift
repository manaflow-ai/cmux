public import SwiftUI
public import CmuxSubrouter

/// The live agent-session → account pinning list. Receives value snapshots
/// only.
/// Per-account routing activity over the last week: a compact horizontal
/// bar chart of session counts. Receives value snapshots only.
public struct SubrouterActivityChartView: View {
    /// The aggregation window shown in the header.
    public static let window: TimeInterval = 7 * 24 * 3600
    private static let maximumRows = 6

    private let activity: [SubrouterSessionStats.AccountActivity]

    /// Creates the chart from precomputed activity rows.
    /// - Parameter activity: Rows from ``SubrouterSessionStats``, most
    ///   active first.
    public init(activity: [SubrouterSessionStats.AccountActivity]) {
        self.activity = activity
    }

    public var body: some View {
        let rows = Array(activity.prefix(Self.maximumRows))
        if !rows.isEmpty {
            let peak = max(1, rows.map(\.sessionCount).max() ?? 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "subrouter.activity.header", defaultValue: "Activity (7 days)"))
                    .font(.system(size: 11, weight: .semibold))
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        Text(row.accountID)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 108, alignment: .leading)
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Color.accentColor.gradient)
                                .frame(width: max(3, proxy.size.width * CGFloat(row.sessionCount) / CGFloat(peak)))
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 5)
                        Text("\(row.sessionCount)")
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(
                        localized: "subrouter.activity.accessibility",
                        defaultValue: "\(row.accountID): \(row.sessionCount) sessions"
                    ))
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

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
