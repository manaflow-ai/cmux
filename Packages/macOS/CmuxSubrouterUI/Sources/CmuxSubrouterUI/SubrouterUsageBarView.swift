public import SwiftUI
public import CmuxSubrouter

/// One quota window rendered as a labeled progress bar with an optional
/// reset countdown. Thresholds match the `sr` CLI: red at ≥90%, yellow at
/// ≥70%, green otherwise.
public struct SubrouterUsageBarView: View {
    private let window: SubrouterUsageWindow

    /// Creates the bar for one window snapshot.
    /// - Parameter window: The window to render.
    public init(window: SubrouterUsageWindow) {
        self.window = window
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(window.displayLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(percentText)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(barColor)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(2, proxy.size.width * window.clampedUsedPercent / 100))
                }
            }
            .frame(height: 3)
            if let reset = window.resetCountdownText {
                Text(reset)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var percentText: String {
        String(
            localized: "subrouter.usage.percentUsed",
            defaultValue: "\(Int(window.clampedUsedPercent.rounded()))%"
        )
    }

    private var barColor: Color {
        if window.clampedUsedPercent >= 90 { return .red }
        if window.clampedUsedPercent >= 70 { return .yellow }
        return .green
    }

    private var accessibilityText: String {
        String(
            localized: "subrouter.usage.accessibility",
            defaultValue: "\(window.displayLabel): \(Int(window.clampedUsedPercent.rounded())) percent used"
        )
    }
}
