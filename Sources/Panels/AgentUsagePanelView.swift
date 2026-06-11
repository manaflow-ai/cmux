import SwiftUI

struct AgentUsagePanelView: View {
    @ObservedObject var panel: AgentUsagePanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0

    var body: some View {
        AgentUsageContentView(store: panel.usageStore)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: appearance.backgroundColor))
            .overlay {
                WorkspaceAttentionFlashRingView(opacity: focusFlashOpacity)
            }
            .simultaneousGesture(TapGesture().onEnded {
                if !isFocused { onRequestPanelFocus() }
            })
            .onChange(of: panel.focusFlashToken) { _, _ in
                triggerFocusFlashAnimation()
            }
    }

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                let animation: Animation = switch segment.curve {
                case .easeIn: .easeIn(duration: segment.duration)
                case .easeOut: .easeOut(duration: segment.duration)
                }
                withAnimation(animation) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }
}

private struct AgentUsageContentView: View {
    @ObservedObject var store: AgentUsageStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let snapshot = store.snapshot {
                if snapshot.days.isEmpty {
                    emptyState
                } else {
                    AgentUsageReportView(snapshot: snapshot)
                }
            } else {
                loadingState
            }
        }
        .onAppear {
            if store.snapshot == nil {
                store.refresh()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(String(localized: "agentUsage.header.title", defaultValue: "Agent Usage (Claude Code / Codex)"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let snapshot = store.snapshot {
                Text(
                    String(
                        format: String(localized: "agentUsage.header.updated", defaultValue: "Updated %@"),
                        snapshot.generatedAt.formatted(date: .omitted, time: .shortened)
                    )
                )
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                PanelHeaderIconButton(
                    systemName: "arrow.clockwise",
                    label: String(localized: "agentUsage.refresh", defaultValue: "Refresh Usage"),
                    action: { store.refresh() }
                )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "agentUsage.loading", defaultValue: "Scanning local agent transcripts…"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(String(
                localized: "agentUsage.empty",
                defaultValue: "No recent usage found in ~/.claude or ~/.codex."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pure value-snapshot subtree: receives an immutable `AgentUsageSnapshot`
/// only, so no row below the ForEach boundary holds a store reference
/// (snapshot boundary policy for list subtrees).
private struct AgentUsageReportView: View {
    let snapshot: AgentUsageSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                totalsSection
                if !snapshot.modelTotals.isEmpty {
                    modelsSection
                }
                daysSection
                Text(String(
                    localized: "agentUsage.footnote",
                    defaultValue: "Costs are estimates from published per-token prices; transcripts older than 30 days are not scanned."
                ))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var totalsSection: some View {
        HStack(spacing: 12) {
            AgentUsageStatCard(
                title: String(localized: "agentUsage.totals.totalTokens", defaultValue: "Total Tokens"),
                value: AgentUsageFormat.tokens(snapshot.totals.total)
            )
            AgentUsageStatCard(
                title: String(localized: "agentUsage.totals.inputOutput", defaultValue: "Input / Output"),
                value: "\(AgentUsageFormat.tokens(snapshot.totals.input)) / \(AgentUsageFormat.tokens(snapshot.totals.output))"
            )
            AgentUsageStatCard(
                title: String(localized: "agentUsage.totals.cache", defaultValue: "Cache Read / Write"),
                value: "\(AgentUsageFormat.tokens(snapshot.totals.cacheRead)) / \(AgentUsageFormat.tokens(snapshot.totals.cacheWrite))"
            )
            AgentUsageStatCard(
                title: String(localized: "agentUsage.totals.estimatedCost", defaultValue: "Est. Cost"),
                value: AgentUsageFormat.cost(snapshot.totalCostUSD)
            )
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "agentUsage.section.models", defaultValue: "By Model (Last 30 Days)"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(snapshot.modelTotals) { model in
                    AgentUsageModelRow(model: model)
                    if model.id != snapshot.modelTotals.last?.id {
                        Divider()
                    }
                }
            }
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var daysSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "agentUsage.section.daily", defaultValue: "Daily Usage"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(snapshot.days) { day in
                    AgentUsageDayRow(day: day)
                    if day.id != snapshot.days.last?.id {
                        Divider()
                    }
                }
            }
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct AgentUsageStatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct AgentUsageModelRow: View {
    let model: AgentUsageModelRollup

    var body: some View {
        HStack(spacing: 8) {
            Text(model.source.displayName)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.07))
                .clipShape(Capsule())
            Text(model.model)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(AgentUsageFormat.tokens(model.tokens.total))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
            Text(AgentUsageFormat.cost(model.costUSD))
                .font(.system(size: 11, design: .rounded))
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct AgentUsageDayRow: View {
    let day: AgentUsageDayRollup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(day.day.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 8)
                Text(AgentUsageFormat.tokens(day.tokens.total))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(AgentUsageFormat.cost(day.costUSD))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .frame(minWidth: 64, alignment: .trailing)
            }
            ForEach(day.models) { model in
                HStack(spacing: 8) {
                    Text(model.source.displayName)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: 70, alignment: .leading)
                    Text(model.model)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(AgentUsageFormat.tokens(model.tokens.total))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Text(AgentUsageFormat.cost(model.costUSD))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 64, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

enum AgentUsageFormat {
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        switch value {
        case 1_000_000_000...:
            return String(format: "%.2fB", value / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.2fM", value / 1_000_000)
        case 10_000...:
            return String(format: "%.1fK", value / 1_000)
        default:
            return "\(count)"
        }
    }

    static func cost(_ cost: Double?) -> String {
        guard let cost else { return "—" }
        return String(format: "$%.2f", cost)
    }
}
