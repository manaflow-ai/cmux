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
            HStack(spacing: 5) {
                Text(window.displayLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(percentText)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(barColor)
                    .frame(minWidth: 30, alignment: .trailing)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(SubrouterPalette.usageFill(for: window.clampedUsedPercent))
                        .frame(width: max(3, proxy.size.width * window.clampedUsedPercent / 100))
                }
            }
            .frame(height: 5)
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
        SubrouterPalette.usageAccent(for: window.clampedUsedPercent)
    }

    private var accessibilityText: String {
        String(
            localized: "subrouter.usage.accessibility",
            defaultValue: "\(window.displayLabel): \(Int(window.clampedUsedPercent.rounded())) percent used"
        )
    }
}
