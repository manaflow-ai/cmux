import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @State private var sidebarWidth: CGFloat = 200
    @State private var sidebarMinX: CGFloat = 0
    @State private var isResizerHovering = false
    @State private var isResizerDragging = false
    private let sidebarHandleWidth: CGFloat = 6
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
            .background(GeometryReader { proxy in
                Color.clear
                    .preference(key: SidebarFramePreferenceKey.self, value: proxy.frame(in: .global))
            })
            .overlay(alignment: .trailing) {
                Color.clear
                    .frame(width: sidebarHandleWidth)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("SidebarResizer")
                    .onHover { hovering in
                        if hovering {
                            if !isResizerHovering {
                                NSCursor.resizeLeftRight.push()
                                isResizerHovering = true
                            }
                        } else if isResizerHovering {
                            if !isResizerDragging {
                                NSCursor.pop()
                                isResizerHovering = false
                            }
                        }
                    }
                    .onDisappear {
                        if isResizerHovering || isResizerDragging {
                            NSCursor.pop()
                            isResizerHovering = false
                            isResizerDragging = false
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if !isResizerDragging {
                                    isResizerDragging = true
                                    if !isResizerHovering {
                                        NSCursor.resizeLeftRight.push()
                                        isResizerHovering = true
                                    }
                                }
                                let nextWidth = max(140, min(360, value.location.x - sidebarMinX + sidebarHandleWidth / 2))
                                withTransaction(Transaction(animation: nil)) {
                                    sidebarWidth = nextWidth
                                }
                            }
                            .onEnded { _ in
                                if isResizerDragging {
                                    isResizerDragging = false
                                    if !isResizerHovering {
                                        NSCursor.pop()
                                    }
                                }
                            }
                    )
            }

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
        .background(Color.clear)
        .onAppear {
            focusedTabId = tabManager.selectedTabId
            tabManager.applyWindowBackgroundForSelectedTab()
        }
        .onChange(of: tabManager.selectedTabId) { newValue in
            focusedTabId = newValue
            tabManager.applyWindowBackgroundForSelectedTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusTab)) { _ in
            sidebarSelection = .tabs
        }
        .onPreferenceChange(SidebarFramePreferenceKey.self) { frame in
            sidebarMinX = frame.minX
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
            .accessibilityIdentifier("Sidebar")

            Spacer()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct SidebarFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
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
        VStack(alignment: .leading, spacing: 4) {
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

            if let subtitle = latestNotificationText {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }

            if let directories = directorySummary {
                Text(directories)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(isSelected ? .white.opacity(0.75) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
            selection = .tabs
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var latestNotificationText: String? {
        guard let notification = notificationStore.latestNotification(forTabId: tab.id) else { return nil }
        let text = notification.body.isEmpty ? notification.title : notification.body
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var directorySummary: String? {
        guard let root = tab.splitTree.root else { return nil }
        let surfaces = root.leaves()
        guard !surfaces.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var seen: Set<String> = []
        var entries: [String] = []
        for surface in surfaces {
            let directory = tab.surfaceDirectories[surface.id] ?? tab.currentDirectory
            let shortened = shortenPath(directory, home: home)
            guard !shortened.isEmpty else { continue }
            if seen.insert(shortened).inserted {
                entries.append(shortened)
            }
        }
        return entries.isEmpty ? nil : entries.joined(separator: " | ")
    }

    private func shortenPath(_ path: String, home: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        if trimmed == home {
            return "~"
        }
        if trimmed.hasPrefix(home + "/") {
            return "~" + trimmed.dropFirst(home.count)
        }
        return trimmed
    }
}

enum SidebarSelection {
    case tabs
    case notifications
}
