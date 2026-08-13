#if os(iOS)
import SwiftUI

/// Visual chrome for one Feed experiment. Interaction content stays identical
/// across designs so Labs changes presentation without changing capabilities.
struct AgentFeedRowChrome<Content: View>: View {
    let design: MobileAgentFeedDesign
    let sourceLabel: String
    let isActionable: Bool
    let actionNeededLabel: String
    let activityLabel: String
    let content: Content

    init(
        design: MobileAgentFeedDesign,
        sourceLabel: String,
        isActionable: Bool,
        actionNeededLabel: String,
        activityLabel: String,
        @ViewBuilder content: () -> Content
    ) {
        self.design = design
        self.sourceLabel = sourceLabel
        self.isActionable = isActionable
        self.actionNeededLabel = actionNeededLabel
        self.activityLabel = activityLabel
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        switch design {
        case .timeline:
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    avatar(size: 40)
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .accessibilityHidden(true)
                }
                content
                    .padding(.bottom, 12)
            }
        case .cards:
            content
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(
                            isActionable
                                ? Color.accentColor.opacity(0.5)
                                : Color.secondary.opacity(0.16)
                        )
                }
                .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
                .padding(.vertical, 6)
        case .compact:
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isActionable ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 4)
                    .accessibilityHidden(true)
                content
            }
            .padding(.vertical, 5)
        case .conversation:
            HStack(alignment: .top, spacing: 10) {
                avatar(size: 32)
                content
                    .padding(12)
                    .background(
                        isActionable ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
            }
            .padding(.vertical, 5)
        case .commandCenter:
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: isActionable ? "bolt.fill" : "waveform.path.ecg")
                    Text(isActionable ? actionNeededLabel : activityLabel)
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(isActionable ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                content.padding(12)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isActionable
                            ? Color.accentColor.opacity(0.7)
                            : Color.secondary.opacity(0.3)
                    )
            }
            .padding(.vertical, 6)
        }
    }

    private func avatar(size: CGFloat) -> some View {
        Text(sourceLabel.prefix(1).uppercased())
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [.accentColor, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Circle()
            )
            .accessibilityHidden(true)
    }
}
#endif
