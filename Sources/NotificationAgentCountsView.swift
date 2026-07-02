import CmuxFoundation
import SwiftUI

/// Single running-agent total shown to the right of the "Notifications"
/// title in both notification surfaces (the Cmd+I titlebar popover and the
/// sidebar notifications page). Clicking it opens a breakdown popover with
/// per-provider counts and every agent's host workspace and running duration.
///
/// Backed by the shared `SleepyAgentCensus` (the self-reported agent PID
/// registry that also drives the Sleepy Mode pets); re-sampled every couple
/// of seconds while visible, and each census pass is O(open tabs). The body
/// only reads a value snapshot; it never writes `@Published` state.
struct NotificationAgentCountsView: View {
    @State private var showBreakdown = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let counts = SleepyModeController.shared.agentCensus.sample(
                at: context.date.timeIntervalSinceReferenceDate
            )
            if counts.total > 0 {
                Button {
                    showBreakdown.toggle()
                } label: {
                    Text("\(counts.total)")
                        .cmuxFont(size: 11, weight: .semibold, design: .rounded)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.summary(total: counts.total))
                .safeHelp(Self.summary(total: counts.total))
                .popover(isPresented: $showBreakdown, arrowEdge: .bottom) {
                    NotificationAgentBreakdownView()
                }
            }
        }
    }

    static func summary(total: Int) -> String {
        let format = String(
            localized: "notifications.agentCounts.summary",
            defaultValue: "%lld coding agents running"
        )
        return String(format: format, Int64(total))
    }
}

/// Breakdown popover: one section per provider (name + count), one row per
/// agent (host workspace + how long its process has been running). Refreshed
/// every second while open so durations tick.
struct NotificationAgentBreakdownView: View {
    struct Row: Equatable, Identifiable {
        let id: String
        let workspaceTitle: String
        let startDate: Date?
    }

    struct Section: Equatable, Identifiable {
        let provider: RunningAgentProvider
        let rows: [Row]
        var id: Int { provider.rawValue }

        var header: String {
            let format = String(
                localized: "notifications.agentCounts.segment",
                defaultValue: "%1$@ %2$lld"
            )
            return String(format: format, provider.displayName, Int64(rows.count))
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let sections = Self.sections(for: SleepyAgentCensus.liveAgents())
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "notifications.agentCounts.popover.title", defaultValue: "Running agents"))
                    .cmuxFont(size: 12, weight: .semibold)
                if sections.isEmpty {
                    Text(String(localized: "notifications.agentCounts.popover.empty", defaultValue: "No agents running"))
                        .cmuxFont(size: 11)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.header)
                                .cmuxFont(size: 11, weight: .semibold)
                            ForEach(section.rows) { row in
                                HStack(spacing: 12) {
                                    Text(row.workspaceTitle)
                                        .cmuxFont(size: 11)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    if let duration = Self.durationText(startDate: row.startDate, now: context.date) {
                                        Text(duration)
                                            .cmuxFont(size: 11, design: .monospaced)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
        }
    }

    /// Groups agents by provider (fixed provider order) and sorts each
    /// section's rows longest-running first; unknown start times sink to the
    /// bottom, ties break by workspace title for a stable list.
    static func sections(for agents: [RunningAgentSnapshot]) -> [Section] {
        RunningAgentProvider.allCases.compactMap { provider in
            let rows = agents
                .filter { $0.provider == provider }
                .sorted { lhs, rhs in
                    switch (lhs.startDate, rhs.startDate) {
                    case let (l?, r?) where l != r: return l < r
                    case (.some, .none): return true
                    case (.none, .some): return false
                    default: return lhs.workspaceTitle < rhs.workspaceTitle
                    }
                }
                .map { Row(id: $0.id, workspaceTitle: $0.workspaceTitle, startDate: $0.startDate) }
            return rows.isEmpty ? nil : Section(provider: provider, rows: rows)
        }
    }

    static func durationText(startDate: Date?, now: Date) -> String? {
        guard let startDate else { return nil }
        let seconds = max(0, now.timeIntervalSince(startDate))
        return Duration.seconds(Int(seconds)).formatted(
            .units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)
        )
    }
}
