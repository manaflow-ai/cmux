#if os(iOS) && DEBUG
import SwiftUI

struct ChatScrollGeometryDebugOverlay: View {
    let snapshot: ChatScrollGeometryDebugSnapshot
    let isAtBottom: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "chat.debug.scroll_geometry.title", defaultValue: "Scroll geometry", bundle: .module))
                .font(.caption2.bold())
            Text("\(bottomLabel): \(isAtBottom ? yesLabel : noLabel) \(distanceLabel): \(format(snapshot.distanceFromBottom))")
            Text("\(offsetLabel): \(format(snapshot.contentOffset))")
            Text("\(visibleLabel): \(format(snapshot.visibleRect))")
            Text("\(contentLabel): \(format(snapshot.contentSize))")
            Text("\(containerLabel): \(format(snapshot.containerSize))")
            Text("\(insetsLabel): \(formatInsets(snapshot))")
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.74), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    private var bottomLabel: String {
        String(localized: "chat.debug.scroll_geometry.bottom", defaultValue: "bottom", bundle: .module)
    }

    private var yesLabel: String {
        String(localized: "chat.debug.scroll_geometry.yes", defaultValue: "yes", bundle: .module)
    }

    private var noLabel: String {
        String(localized: "chat.debug.scroll_geometry.no", defaultValue: "no", bundle: .module)
    }

    private var distanceLabel: String {
        String(localized: "chat.debug.scroll_geometry.distance", defaultValue: "distance", bundle: .module)
    }

    private var offsetLabel: String {
        String(localized: "chat.debug.scroll_geometry.offset", defaultValue: "offset", bundle: .module)
    }

    private var visibleLabel: String {
        String(localized: "chat.debug.scroll_geometry.visible", defaultValue: "visible", bundle: .module)
    }

    private var contentLabel: String {
        String(localized: "chat.debug.scroll_geometry.content", defaultValue: "content", bundle: .module)
    }

    private var containerLabel: String {
        String(localized: "chat.debug.scroll_geometry.container", defaultValue: "container", bundle: .module)
    }

    private var insetsLabel: String {
        String(localized: "chat.debug.scroll_geometry.insets", defaultValue: "insets", bundle: .module)
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.0f", value)
    }

    private func format(_ point: CGPoint) -> String {
        "(\(format(point.x)),\(format(point.y)))"
    }

    private func format(_ size: CGSize) -> String {
        "(\(format(size.width)),\(format(size.height)))"
    }

    private func format(_ rect: CGRect) -> String {
        "(\(format(rect.minX)),\(format(rect.minY)),\(format(rect.width)),\(format(rect.height)))"
    }

    private func formatInsets(_ snapshot: ChatScrollGeometryDebugSnapshot) -> String {
        "(\(format(snapshot.contentInsetTop)),\(format(snapshot.contentInsetLeading)),\(format(snapshot.contentInsetBottom)),\(format(snapshot.contentInsetTrailing)))"
    }
}
#endif
