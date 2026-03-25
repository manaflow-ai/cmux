import SwiftUI

extension Notification.Name {
    static let cmuxSidebarSwitchToSearch = Notification.Name("cmuxSidebarSwitchToSearch")
    static let cmuxSidebarSwitchToExplorer = Notification.Name("cmuxSidebarSwitchToExplorer")
}

/// Tab selector below the traffic lights — switches between Workspaces, Explorer, and Search.
struct SidebarTabSelector: View {
    @Binding var selected: ContentView.SidebarTab

    private let tabs: [(ContentView.SidebarTab, String)] = [
        (.workspaces, "square.stack"),
        (.explorer, "folder"),
        (.search, "magnifyingglass"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Tab buttons
            HStack(spacing: 2) {
                ForEach(tabs, id: \.0) { tab, icon in
                    Button {
                        selected = tab
                    } label: {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: selected == tab ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .foregroundStyle(selected == tab ? .primary : .tertiary)
                            .background(
                                selected == tab
                                    ? RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08))
                                    : nil
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }
}
