import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @State private var sidebarWidth: CGFloat = 200
    @State private var sidebarDragStart: CGFloat?
    @FocusState private var focusedTabId: UUID?
    @State private var sidebarSelection: SidebarSelection = .tabs

    var body: some View {
        HStack(spacing: 0) {
            // Vertical Tabs Sidebar
            VerticalTabsSidebar(
                sidebarWidth: sidebarWidth,
                selection: $sidebarSelection
            )
                .frame(width: sidebarWidth)

            // Divider
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if sidebarDragStart == nil {
                                sidebarDragStart = sidebarWidth
                            }
                            let base = sidebarDragStart ?? sidebarWidth
                            sidebarWidth = max(140, min(360, base + value.translation.width))
                        }
                        .onEnded { _ in
                            sidebarDragStart = nil
                        }
                )

            // Terminal Content - use ZStack to keep all surfaces alive
            ZStack {
                ZStack {
                    ForEach(tabManager.tabs) { tab in
                        let isActive = tabManager.selectedTabId == tab.id
                        TerminalSplitTreeView(tab: tab, isTabActive: isActive)
                            .opacity(isActive ? 1 : 0)
                            .allowsHitTesting(isActive)
                            .focusable()
                            .focused($focusedTabId, equals: tab.id)
                    }
                }
                .opacity(sidebarSelection == .tabs ? 1 : 0)
                .allowsHitTesting(sidebarSelection == .tabs)

                NotificationsPage(selection: $sidebarSelection)
                    .opacity(sidebarSelection == .notifications ? 1 : 0)
                    .allowsHitTesting(sidebarSelection == .notifications)
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
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusTab)) { _ in
            sidebarSelection = .tabs
        }
    }
}

struct VerticalTabsSidebar: View {
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    let sidebarWidth: CGFloat
    @Binding var selection: SidebarSelection

    var body: some View {
        VStack(spacing: 0) {
            // Header with title
            HStack {
                Button(action: { selection = .tabs }) {
                    Text("Tabs")
                        .font(.headline)
                        .foregroundColor(selection == .tabs ? .primary : .secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: { selection = .notifications }) {
                    HStack(spacing: 6) {
                        Image(systemName: "bell")
                            .font(.system(size: 12, weight: .medium))
                        if notificationStore.unreadCount > 0 {
                            Text("\(notificationStore.unreadCount)")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor))
                                .foregroundColor(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(selection == .notifications ? .primary : .secondary)

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
                        TabItemView(tab: tab, selection: $selection)
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
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @ObservedObject var tab: Tab
    @Binding var selection: SidebarSelection
    @State private var isHovering = false

    var isSelected: Bool {
        tabManager.selectedTabId == tab.id
    }

    var body: some View {
        HStack(spacing: 8) {
            let unreadCount = notificationStore.unreadCount(forTabId: tab.id)
            if unreadCount > 0 {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.white.opacity(0.25) : Color.accentColor)
                    Text("\(unreadCount)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(width: 16, height: 16)
            }

            Text(tab.title)
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Button(action: { tabManager.closeTab(tab) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 16, height: 16)
            .opacity((isHovering || isSelected) && tabManager.tabs.count > 1 ? 1 : 0)
            .allowsHitTesting((isHovering || isSelected) && tabManager.tabs.count > 1)
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
            selection = .tabs
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

enum SidebarSelection {
    case tabs
    case notifications
}
