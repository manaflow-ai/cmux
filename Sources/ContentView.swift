import SwiftUI

struct ContentView: View {
    @EnvironmentObject var tabManager: TabManager
    @State private var sidebarWidth: CGFloat = 200
    @FocusState private var focusedTabId: UUID?

    var body: some View {
        HStack(spacing: 0) {
            // Vertical Tabs Sidebar
            VerticalTabsSidebar(sidebarWidth: sidebarWidth)
                .frame(width: sidebarWidth)

            // Divider
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)

            // Terminal Content - use ZStack to keep all surfaces alive
            ZStack {
                ForEach(tabManager.tabs) { tab in
                    let isActive = tabManager.selectedTabId == tab.id
                    GhosttyTerminalView(terminalSurface: tab.terminalSurface, isActive: isActive)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .focusable()
                        .focused($focusedTabId, equals: tab.id)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            focusedTabId = tabManager.selectedTabId
        }
        .onChange(of: tabManager.selectedTabId) { newValue in
            focusedTabId = newValue
        }
    }
}

struct VerticalTabsSidebar: View {
    @EnvironmentObject var tabManager: TabManager
    let sidebarWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // Header with title
            HStack {
                Text("Tabs")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { tabManager.addTab() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Tab List
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(tabManager.tabs) { tab in
                        TabItemView(tab: tab)
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct TabItemView: View {
    @EnvironmentObject var tabManager: TabManager
    @ObservedObject var tab: Tab
    @State private var isHovering = false

    var isSelected: Bool {
        tabManager.selectedTabId == tab.id
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .white : .secondary)

            Text(tab.title)
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if isHovering || isSelected {
                Button(action: { tabManager.closeTab(tab) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
                }
                .buttonStyle(.plain)
                .opacity(tabManager.tabs.count > 1 ? 1 : 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : (isHovering ? Color(nsColor: .controlBackgroundColor).opacity(0.5) : Color.clear))
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            tabManager.selectTab(tab)
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
