import CmuxAppKitSupportUI
import CmuxUsage
import SwiftUI

/// Sidebar-footer entry point for the multi-provider usage HUD.
///
/// Owns the on-demand `UsageStore` (safe here: the footer is a direct child of the
/// sidebar `HStack`, **not** a row below a `LazyVStack`/`List` boundary, so holding an
/// `ObservableObject` does not violate cmux's snapshot-boundary law). The active provider
/// is resolved off the body path (in `.task` and on tap) and cached in `@State`, so the
/// footer adds no new `TabManager` observation and does no work in `body` on the
/// typing-latency-sensitive path.
///
/// Fetching is user-driven only (appear + tap), matching the store's no-background-timer
/// contract. Provider usage rides undocumented response headers for Claude/Grok — an
/// unversioned side channel — so every failure degrades to a label, never a crash.
struct UsageFooterHost: View {
    @StateObject private var store = UsageStore()
    @State private var isPanelPresented = false
    /// Provider backing the focused agent surface, resolved off the body path (in `.task`
    /// and on tap) — never during `body`, since resolving it calls into
    /// `SharedLiveAgentIndex` which schedules refresh work, and this footer sits on a
    /// typing-latency-sensitive path where body must stay side-effect free.
    @State private var activeProvider: UsageProvider?

    var body: some View {
        let snapshot = activeProvider.flatMap { store.snapshot(for: $0) }
        let tile = UsageDisplay.tileModel(provider: activeProvider, snapshot: snapshot)

        UsageFooterTile(model: tile) {
            let resolved = Self.resolveActiveProvider()
            activeProvider = resolved
            isPanelPresented.toggle()
            Task { await store.refresh(UsageProviderRegistry.gaugeable) }
        }
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPanelPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            UsageLimitsPanel(
                title: String(localized: "usage.panel.title", defaultValue: "Usage limits"),
                rows: UsageDisplay.accountRows(from: store.snapshots),
                emptyMessage: String(localized: "usage.panel.empty", defaultValue: "No usage data available yet.")
            )
        })
        .task {
            // Resolve + refresh the active provider on appear (off the body path). The panel
            // refreshes the rest on open. The tile reflects focus as of appear/tap, not live
            // focus churn — the multi-provider panel is the exhaustive surface.
            let resolved = Self.resolveActiveProvider()
            activeProvider = resolved
            if let resolved { await store.refresh(resolved) }
        }
        .accessibilityIdentifier("SidebarUsageFooterTile")
    }

    /// Resolve the provider backing the currently focused agent surface, if any.
    /// Calls into `SharedLiveAgentIndex` (which may schedule refresh work), so it is only
    /// ever invoked from action/task closures, never from `body`.
    @MainActor
    static func resolveActiveProvider() -> UsageProvider? {
        guard
            let workspace = AppDelegate.shared?.tabManager?.selectedWorkspace,
            let panelId = workspace.focusedPanelId,
            let kind = SharedLiveAgentIndex.shared.snapshot(workspaceId: workspace.id, panelId: panelId)?.kind
        else { return nil }
        return UsageDisplay.provider(for: kind)
    }
}

/// Pure mapping from `UsageSnapshot` domain values to the value-driven view models.
/// All strings localized here; the `CmuxUsage` package holds no localization.
enum UsageDisplay {
    /// Map a live-agent kind to a usage provider (nil for kinds with no usage surface).
    static func provider(for kind: RestorableAgentKind) -> UsageProvider? {
        switch kind {
        case .claude: return .claude
        case .codex: return .codex
        case .grok: return .grok
        case .kimi: return .kimi
        case .gemini: return .gemini
        default: return nil
        }
    }

    // MARK: Footer tile

    static func tileModel(provider: UsageProvider?, snapshot: UsageSnapshot?) -> UsageTileModel {
        guard let provider else {
            // No agent focused (or an agent with no usage surface): neutral resting chip.
            return UsageTileModel(
                providerName: String(localized: "usage.tile.none", defaultValue: "Usage"),
                iconAssetName: nil,
                usedPercent: nil,
                detail: "—",
                state: .unavailable
            )
        }
        let name = provider.displayName
        guard let snapshot else {
            // Linked but not yet fetched.
            return UsageTileModel(providerName: name, iconAssetName: nil, usedPercent: nil,
                                  detail: "…", state: .degraded)
        }

        switch snapshot.freshness {
        case .live, .stale:
            let window = primaryWindow(snapshot.windows)
            let pct = window?.usedPercent
            let detail = pct.map { "\(Int($0.rounded()))%" }
                ?? stateLabel(for: snapshot.freshness)
            let state: UsageTileModel.State = (snapshot.freshness.isLive ? .ok : .degraded)
            return UsageTileModel(providerName: name, iconAssetName: nil, usedPercent: pct,
                                  detail: detail, state: state)
        case .rateLimited:
            return UsageTileModel(providerName: name, iconAssetName: nil, usedPercent: nil,
                                  detail: stateLabel(for: snapshot.freshness), state: .degraded)
        case .signedOut, .notInstalled, .unsupported:
            return UsageTileModel(providerName: name, iconAssetName: nil, usedPercent: nil,
                                  detail: stateLabel(for: snapshot.freshness), state: .unavailable)
        }
    }

    // MARK: Multi-account panel

    static func accountRows(from snapshots: [UsageProvider: UsageSnapshot]) -> [UsageAccountRowModel] {
        // Stable ordering matches the gaugeable list so the panel doesn't reshuffle.
        UsageProviderRegistry.gaugeable.compactMap { provider in
            guard let snapshot = snapshots[provider] else { return nil }
            return UsageAccountRowModel(
                id: provider.rawValue,
                providerName: provider.displayName,
                iconAssetName: nil,
                statusLabel: statusLabel(for: snapshot),
                bars: snapshot.windows.map(bar(for:))
            )
        }
    }

    private static func bar(for window: UsageWindow) -> UsageAccountRowModel.Bar {
        UsageAccountRowModel.Bar(
            label: windowLabel(window),
            usedPercent: window.usedPercent,
            detail: windowDetail(window)
        )
    }

    // MARK: Labels

    private static func primaryWindow(_ windows: [UsageWindow]) -> UsageWindow? {
        // Prefer the shortest rolling window with a percentage (the one nearest a limit).
        windows
            .filter { $0.usedPercent != nil }
            .min { lhs, rhs in rollingSeconds(lhs) < rollingSeconds(rhs) }
    }

    private static func rollingSeconds(_ window: UsageWindow) -> Int {
        if case .rolling(let seconds) = window.kind { return seconds }
        return .max // non-rolling windows sort last
    }

    private static func windowLabel(_ window: UsageWindow) -> String {
        switch window.kind {
        case .rolling(let seconds):
            return durationLabel(seconds: seconds)
        case .credits:
            return String(localized: "usage.window.credits", defaultValue: "Credits")
        case .quota(let unit):
            return unit
        }
    }

    /// Compact rolling-window label. Uses fixed 5h/Weekly for the two common windows,
    /// otherwise an abbreviated duration (localized by Foundation).
    private static func durationLabel(seconds: Int) -> String {
        switch seconds {
        case 18000: return String(localized: "usage.window.5h", defaultValue: "5h")
        case 604800: return String(localized: "usage.window.weekly", defaultValue: "Weekly")
        default:
            let fmt = DateComponentsFormatter()
            fmt.allowedUnits = [.day, .hour, .minute]
            fmt.unitsStyle = .abbreviated
            fmt.maximumUnitCount = 1
            return fmt.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
        }
    }

    private static func windowDetail(_ window: UsageWindow) -> String {
        switch window.kind {
        case .rolling:
            if let resetAt = window.resetAt {
                return resetDetail(resetAt)
            }
            if let pct = window.usedPercent {
                return "\(Int(pct.rounded()))%"
            }
            return ""
        case .credits:
            if let remaining = window.creditsRemaining {
                return compactNumber(remaining)
            }
            return ""
        case .quota:
            if let remaining = window.remaining {
                // String(format:) with a localized format string — NOT an interpolated
                // `defaultValue`, which does not reliably bind its argument to the
                // catalog value looked up by key (would render a literal "%@" in ja).
                return String(
                    format: String(localized: "usage.detail.remaining", defaultValue: "%@ left"),
                    compactNumber(remaining)
                )
            }
            return ""
        }
    }

    private static func resetDetail(_ resetAt: Date) -> String {
        let seconds = max(0, resetAt.timeIntervalSinceNow)
        let fmt = DateComponentsFormatter()
        fmt.allowedUnits = [.day, .hour, .minute]
        fmt.unitsStyle = .abbreviated
        fmt.maximumUnitCount = 1
        let duration = fmt.string(from: seconds) ?? ""
        return String(
            format: String(localized: "usage.detail.resetsIn", defaultValue: "resets in %@"),
            duration
        )
    }

    private static func statusLabel(for snapshot: UsageSnapshot) -> String {
        let base = stateLabel(for: snapshot.freshness)
        if let plan = snapshot.planLabel, !plan.isEmpty {
            return "\(plan) · \(base)"
        }
        return base
    }

    private static func stateLabel(for freshness: UsageFreshness) -> String {
        switch freshness {
        case .live: return String(localized: "usage.state.live", defaultValue: "live")
        case .stale: return String(localized: "usage.state.stale", defaultValue: "stale")
        case .signedOut: return String(localized: "usage.state.signedOut", defaultValue: "signed out")
        case .notInstalled: return String(localized: "usage.state.notInstalled", defaultValue: "not installed")
        case .unsupported: return String(localized: "usage.state.unsupported", defaultValue: "no limits")
        case .rateLimited: return String(localized: "usage.state.rateLimited", defaultValue: "rate limited")
        }
    }

    /// Human-compact number (e.g. 1.5M, 53K). Non-localized digits by design.
    private static func compactNumber(_ value: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        switch abs(value) {
        case 1_000_000...:
            fmt.maximumFractionDigits = 1
            return (fmt.string(from: NSNumber(value: value / 1_000_000)) ?? "\(value)") + "M"
        case 1_000...:
            fmt.maximumFractionDigits = 0
            return (fmt.string(from: NSNumber(value: value / 1_000)) ?? "\(value)") + "K"
        default:
            fmt.maximumFractionDigits = 0
            return fmt.string(from: NSNumber(value: value)) ?? "\(value)"
        }
    }
}

private extension UsageFreshness {
    var isLive: Bool {
        if case .live = self { return true }
        return false
    }
}
