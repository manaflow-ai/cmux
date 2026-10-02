import CmuxFoundation
import SwiftUI

/// Refresh Cloud Machines, at the bottom right of the Cloud panel. As wide as
/// its label, with the tree's hover fill, so it reads like a quiet row action.
/// While a refresh runs it shows a spinner in place of its icon and ignores
/// clicks.
struct CloudRefreshMachinesButton: View {
    let isRefreshing: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String {
        String(localized: "cloudTree.action.refreshCloudMachines", defaultValue: "Refresh Cloud Machines")
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button(action: action) {
                HStack(spacing: 5) {
                    Group {
                        if isRefreshing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .frame(width: 12, height: 12)
                    Text(title)
                        .cmuxFont(size: 11.5)
                        .lineLimit(1)
                }
                .foregroundStyle(isHovered && !isRefreshing ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: CloudTreeHoverStyle.cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(isHovered && !isRefreshing ? CloudTreeHoverStyle.hoverOpacity : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: isHovered ? CloudTreeHoverStyle.fadeIn : CloudTreeHoverStyle.fadeOut), value: isHovered)
            .help(title)
            .accessibilityLabel(title)
            .accessibilityIdentifier("CloudRefreshMachinesButton")
        }
        .padding(.horizontal, RightSidebarChromeMetrics.barHorizontalPadding - 2)
        .padding(.vertical, 6)
    }
}
