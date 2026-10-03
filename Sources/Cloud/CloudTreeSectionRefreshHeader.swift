import CmuxCloud
import CmuxFoundation
import SwiftUI

/// A section header ("Cloud Machines 3/5", "My Devices") with its refresh
/// icon right after the count, small and in the count's color.
struct CloudTreeSectionRefreshHeader: View {
    let title: String
    let count: CloudTreeGroupCount?
    let style: CloudTreeStyle
    let refresh: CloudTreeSectionRefresh
    /// The icon's tooltip and accessibility label.
    let label: String
    let action: () -> Void
    /// Reports the icon's frame in `CloudTreePassthroughHostingView.coordinateSpace`,
    /// the only spot of the header that takes a click instead of the row.
    let onInteractiveFrame: (CGRect?) -> Void

    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: scaled(4)) {
            // The shared header, hugging its title and count (its own spacer
            // collapses) so the icon sits right after the count.
            CloudTreeGroupRowContent(title: title, count: count, style: style)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, -style.rowGrid.trailingPadding)
            refreshButton
            Spacer(minLength: 0)
        }
        .padding(.trailing, style.rowGrid.trailingPadding)
        .onDisappear { onInteractiveFrame(nil) }
    }

    private var refreshButton: some View {
        Button(action: action) {
            Group {
                if refresh.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: scaled(max(8, style.detailSize - 2)), weight: .semibold))
                        .foregroundStyle(isHovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
            }
            // The same hit area and hover fill as the headers' + and ⋯
            // (`MachinesChromeIconButton`); the glyph keeps its own size.
            .frame(width: 22, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: RightSidebarChromeMetrics.buttonCornerRadius, style: .continuous)
                .fill(isHovered && !refresh.isRefreshing ? Color.primary.opacity(0.06) : Color.clear)
        )
        .disabled(refresh.isRefreshing)
        .onHover { isHovered = $0 }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(CloudTreePassthroughHostingView.coordinateSpace))
        } action: { onInteractiveFrame($0) }
        .help(label)
        .accessibilityLabel(label)
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        GlobalFontMagnification.scaledSize(value, percent: magnification)
    }
}
