import SwiftUI
import AppKit

/// Minimal tab bar for a paper layout pane. Matches the visual style of the
/// previous Bonsplit tab bar: 30pt height, window background color, accent-colored
/// selected indicator, separator line along the bottom.
struct PaperTabBarView: View {
    let pane: PaperPane
    let controller: PaperLayoutController
    let isFocused: Bool

    private let barHeight: CGFloat = 30
    private let tabMinWidth: CGFloat = 48
    private let tabMaxWidth: CGFloat = 220
    private let iconSize: CGFloat = 14
    private let titleFont: Font = .system(size: 11)
    private let indicatorHeight: CGFloat = 2

    var body: some View {
        HStack(spacing: 0) {
            // Tab items
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(pane.tabs, id: \.id) { tabItem in
                        tabItemView(tabItem)
                    }
                }
            }

            Spacer(minLength: 0)

            // Split buttons
            splitButtons
        }
        .frame(height: barHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            // Bottom separator
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        .saturation(isFocused ? 1.0 : 0.0)
    }

    @ViewBuilder
    private func tabItemView(_ tabItem: PaperTabItem) -> some View {
        let isSelected = tabItem.id == pane.selectedTabId
        let tab = PaperTab(from: tabItem)

        Button {
            controller.selectTab(tab.id)
        } label: {
            HStack(spacing: 6) {
                // Icon
                if let iconName = tabItem.icon {
                    Image(systemName: iconName)
                        .font(.system(size: iconSize))
                        .frame(width: iconSize, height: iconSize)
                }

                // Title
                Text(tabItem.title)
                    .font(titleFont)
                    .lineLimit(1)

                Spacer(minLength: 0)

                // Close button
                if isSelected {
                    Button {
                        controller.closeTab(tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else if tabItem.isDirty {
                    Circle()
                        .fill(Color(nsColor: .labelColor).opacity(0.6))
                        .frame(width: 8, height: 8)
                } else if tabItem.showsNotificationBadge {
                    Circle()
                        .fill(Color(nsColor: .systemBlue))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 6)
            .frame(minWidth: tabMinWidth, maxWidth: tabMaxWidth, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
        .overlay(alignment: .top) {
            // Selected indicator bar
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: indicatorHeight)
                    .offset(y: 0.5)
            }
        }
        .overlay(alignment: .trailing) {
            // Right separator
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
    }

    @ViewBuilder
    private var splitButtons: some View {
        HStack(spacing: 4) {
            Button {
                if let paneId = controller.focusedPaneId {
                    controller.requestNewTab(kind: "terminal", inPane: paneId)
                }
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Terminal")
        }
        .padding(.trailing, 8)
    }
}
