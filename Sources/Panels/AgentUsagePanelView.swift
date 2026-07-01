import SwiftUI

/// Pane-hosted dashboard view for `AgentUsagePanel`. Handles the panel chrome
/// (theme background, attention flash ring, tap-to-focus) and delegates the
/// content to `AgentUsageContentView`.
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

    /// Replays the shared attention flash pattern. Mirrors the scheduling in
    /// `RightSidebarToolPanelView`, the codebase's reference implementation
    /// for the flash ring.
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

/// Header plus dashboard body; owns the store observation so the chrome layer
/// above doesn't re-render on every snapshot change.
private struct AgentUsageContentView: View {
    @ObservedObject var store: AgentUsageStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let snapshot = store.snapshot {
                if snapshot.days.isEmpty && snapshot.openRouterCredits == nil {
                    emptyState
                } else {
                    AgentUsageReportView(snapshot: snapshot, openRouterError: store.openRouterError)
                }
            } else {
                loadingState
            }
        }
        .onAppear {
            store.refreshIfStale()
        }
    }

    /// 30pt header bar: title, last-updated stamp, refresh control.
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

    /// Shown before the first scan completes.
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

    /// Shown when no transcripts produced usage inside the scan window.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(String(
                localized: "agentUsage.empty",
                defaultValue: "No recent usage found in ~/.claude, ~/.codex, or ~/.local/share/opencode. Add an OpenRouter key in Settings to include OpenRouter usage."
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
    let openRouterError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let openRouterError {
                    Label(openRouterError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                totalsSection
                if let credits = snapshot.openRouterCredits {
                    openRouterCreditsSection(credits)
                }
                if !snapshot.rateWindows.isEmpty {
                    windowsSection
                }
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

    /// Four stat cards: total tokens, input/output, cache read/write, est. cost.
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
                title: String(localized: "agentUsage.totals.estimatedCost", defaultValue: "Est. API Cost"),
                value: AgentUsageFormat.cost(snapshot.totalCostUSD)
            )
        }
    }

    /// OpenRouter account balance, shown as three cards.
    private func openRouterCreditsSection(_ credits: OpenRouterCredits) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "agentUsage.section.openRouter", defaultValue: "OpenRouter Balance"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                AgentUsageStatCard(
                    title: String(localized: "agentUsage.openRouter.remaining", defaultValue: "Remaining"),
                    value: AgentUsageFormat.cost(credits.remaining)
                )
                AgentUsageStatCard(
                    title: String(localized: "agentUsage.openRouter.purchased", defaultValue: "Purchased"),
                    value: AgentUsageFormat.cost(credits.totalCredits)
                )
                AgentUsageStatCard(
                    title: String(localized: "agentUsage.openRouter.used", defaultValue: "Used"),
                    value: AgentUsageFormat.cost(credits.totalUsage)
                )
            }
        }
    }

    /// Plan-limit window cards in a two-column grid.
    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "agentUsage.section.windows", defaultValue: "Plan Limit Windows"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(snapshot.rateWindows) { window in
                    AgentUsageRateWindowCard(window: window)
                }
            }
        }
    }

    /// Per-model totals across the scan window.
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

    /// Daily rollups, newest day first, with per-model sub-rows.
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

/// One plan-limit window card: provider-reported windows render a progress
/// bar with the reported percentage; estimated windows render tokens and cost.
private struct AgentUsageRateWindowCard: View {
    let window: AgentUsageRateWindow

    private var kindLabel: String {
        switch window.kind {
        case .fiveHour:
            return String(localized: "agentUsage.window.fiveHour", defaultValue: "5-Hour Window")
        case .weekly:
            return String(localized: "agentUsage.window.weekly", defaultValue: "Weekly")
        }
    }

    private var sourceLabel: String {
        window.isProviderReported
            ? String(localized: "agentUsage.window.reported", defaultValue: "Reported by Codex CLI")
            : String(localized: "agentUsage.window.estimated", defaultValue: "Estimated from transcripts")
    }

    private var resetLabel: String? {
        if let end = window.windowEnd {
            return String(
                format: String(localized: "agentUsage.window.resets", defaultValue: "Resets %@"),
                end.formatted(date: .abbreviated, time: .shortened)
            )
        }
        if window.kind == .weekly {
            return String(localized: "agentUsage.window.rolling", defaultValue: "Rolling 7 days")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(window.source.displayName) · \(kindLabel)")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 8)
                Text(sourceLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if let percent = window.usedPercent {
                let fraction = min(max(percent / 100, 0), 1)
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(percent >= 90 ? Color.red : (percent >= 70 ? Color.orange : Color.accentColor))
                Text(
                    String(
                        format: String(localized: "agentUsage.window.usedPercent", defaultValue: "%d%% used"),
                        Int(percent.rounded())
                    )
                )
                .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            HStack(spacing: 8) {
                if !window.tokens.isEmpty {
                    Text(
                        String(
                            format: String(localized: "agentUsage.window.usage", defaultValue: "%@ tokens · est. %@"),
                            AgentUsageFormat.tokens(window.tokens.total),
                            AgentUsageFormat.cost(window.costUSD)
                        )
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let resetLabel {
                    Text(resetLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Small labeled stat card used in the totals row.
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

/// One row of the per-model totals list.
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

/// One day group of the daily usage list, with per-model sub-rows.
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

/// Locale-aware display formatting for the dashboard's numbers.
enum AgentUsageFormat {
    /// Formats a token count compactly (e.g. "233.54M") using the user's
    /// locale conventions for digits, separators, and unit abbreviations.
    static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
    }

    /// Formats an estimated cost as USD currency using the user's locale
    /// conventions; the estimate is inherently denominated in USD.
    static func cost(_ cost: Double?) -> String {
        guard let cost else { return "—" }
        return cost.formatted(.currency(code: "USD"))
    }
}
