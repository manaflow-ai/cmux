public import SwiftUI

/// Immutable display model for the footer tile. The app builds this from a
/// `UsageSnapshot` (resolving the active provider) and passes localized strings in —
/// the view holds no store reference (snapshot-boundary safe).
public struct UsageTileModel: Equatable, Sendable {
    public enum State: Sendable, Equatable { case ok, degraded, unavailable }

    public var providerName: String
    public var iconAssetName: String?
    /// Primary window utilization 0…100, or nil when there's no gauge (credits/quota-only/unlimited).
    public var usedPercent: Double?
    /// Compact trailing text, already localized (e.g. "3h", "59%", "Unlimited").
    public var detail: String
    public var state: State

    public init(providerName: String, iconAssetName: String?, usedPercent: Double?, detail: String, state: State) {
        self.providerName = providerName
        self.iconAssetName = iconAssetName
        self.usedPercent = usedPercent
        self.detail = detail
        self.state = state
    }
}

/// A compact footer chip: optional provider icon + a thin utilization ring + detail text.
public struct UsageFooterTile: View {
    private let model: UsageTileModel
    private let onTap: () -> Void
    @State private var isHovered = false

    public init(model: UsageTileModel, onTap: @escaping () -> Void) {
        self.model = model
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if let usedPercent = model.usedPercent {
                    UsageRing(percent: usedPercent)
                        .frame(width: 12, height: 12)
                }
                Text(model.detail)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(model.state == .unavailable
                        ? Color(nsColor: .tertiaryLabelColor)
                        : Color(nsColor: .secondaryLabelColor))
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .accessibilityLabel("\(model.providerName): \(model.detail)")
    }
}

/// A thin circular utilization gauge (no house style existed to conflict with).
public struct UsageRing: View {
    private let percent: Double
    public init(percent: Double) { self.percent = percent }

    private var fraction: Double { max(0, min(1, percent / 100)) }
    private var tint: Color {
        switch fraction {
        case ..<0.75: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }

    public var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// One row in the multi-account panel: a provider account and its windows.
public struct UsageAccountRowModel: Identifiable, Equatable, Sendable {
    public struct Bar: Equatable, Sendable {
        public var label: String        // localized, e.g. "5h" / "Weekly" / "Tokens"
        public var usedPercent: Double?
        public var detail: String       // localized, e.g. "resets in 3h" / "53M left"
        public init(label: String, usedPercent: Double?, detail: String) {
            self.label = label; self.usedPercent = usedPercent; self.detail = detail
        }
    }
    public var id: String
    public var providerName: String
    public var iconAssetName: String?
    public var statusLabel: String      // localized freshness/plan, e.g. "Max · live" / "Unlimited"
    public var bars: [Bar]
    public init(id: String, providerName: String, iconAssetName: String?, statusLabel: String, bars: [Bar]) {
        self.id = id; self.providerName = providerName; self.iconAssetName = iconAssetName
        self.statusLabel = statusLabel; self.bars = bars
    }
}

/// Multi-account usage panel (popover body). Pure value-driven; no store reference.
public struct UsageLimitsPanel: View {
    private let title: String
    private let rows: [UsageAccountRowModel]
    private let emptyMessage: String

    public init(title: String, rows: [UsageAccountRowModel], emptyMessage: String) {
        self.title = title
        self.rows = rows
        self.emptyMessage = emptyMessage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if rows.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            } else {
                ForEach(rows) { row in
                    UsageAccountRow(row: row)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 260)
    }
}

private struct UsageAccountRow: View {
    let row: UsageAccountRowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.providerName).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Text(row.statusLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            ForEach(Array(row.bars.enumerated()), id: \.offset) { _, bar in
                HStack(spacing: 6) {
                    Text(bar.label).font(.system(size: 10)).frame(width: 52, alignment: .leading)
                    UsageBar(percent: bar.usedPercent)
                    Text(bar.detail)
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 76, alignment: .trailing)
                }
            }
        }
    }
}

/// A thin horizontal utilization bar; renders a neutral track when percent is nil.
public struct UsageBar: View {
    private let percent: Double?
    public init(percent: Double?) { self.percent = percent }

    private var fraction: Double { max(0, min(1, (percent ?? 0) / 100)) }
    private var tint: Color {
        switch fraction {
        case ..<0.75: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if percent != nil {
                    Capsule().fill(tint).frame(width: geo.size.width * fraction)
                }
            }
        }
        .frame(height: 5)
    }
}
