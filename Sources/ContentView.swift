import AppKit
import SwiftUI

final class SidebarState: ObservableObject {
    @Published var isVisible: Bool = true

    func toggle() {
        isVisible.toggle()
    }
}

struct ContentView: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var sidebarState: SidebarState
    @State private var sidebarWidth: CGFloat = 200
    @State private var sidebarMinX: CGFloat = 0
    @State private var isResizerHovering = false
    @State private var isResizerDragging = false
    private let sidebarHandleWidth: CGFloat = 6
    @State private var sidebarSelection: SidebarSelection = .tabs
    @State private var selectedTabIds: Set<UUID> = []
    @State private var lastSidebarSelectionIndex: Int? = nil

    var body: some View {
        HStack(spacing: 0) {
            if sidebarState.isVisible {
                VerticalTabsSidebar(
                    selection: $sidebarSelection,
                    selectedTabIds: $selectedTabIds,
                    lastSidebarSelectionIndex: $lastSidebarSelectionIndex
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
            }

            // Terminal Content - use ZStack to keep all surfaces alive
            ZStack {
                ZStack {
                    ForEach(tabManager.tabs) { tab in
                        let isActive = tabManager.selectedTabId == tab.id
                        TerminalSplitTreeView(tab: tab, isTabActive: isActive)
                            .opacity(isActive ? 1 : 0)
                            .allowsHitTesting(isActive)
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
            tabManager.applyWindowBackgroundForSelectedTab()
            if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                selectedTabIds = [selectedId]
                lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
            }
        }
        .onChange(of: tabManager.selectedTabId) { newValue in
            tabManager.applyWindowBackgroundForSelectedTab()
            guard let newValue else { return }
            if selectedTabIds.count <= 1 {
                selectedTabIds = [newValue]
                lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == newValue }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusTab)) { _ in
            sidebarSelection = .tabs
        }
        .onReceive(tabManager.$tabs) { tabs in
            let existingIds = Set(tabs.map { $0.id })
            selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
            if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                selectedTabIds = [selectedId]
            }
            if let lastIndex = lastSidebarSelectionIndex, lastIndex >= tabs.count {
                if let selectedId = tabManager.selectedTabId {
                    lastSidebarSelectionIndex = tabs.firstIndex { $0.id == selectedId }
                } else {
                    lastSidebarSelectionIndex = nil
                }
            }
        }
        .onPreferenceChange(SidebarFramePreferenceKey.self) { frame in
            sidebarMinX = frame.minX
        }
        .background(WindowAccessor { window in
            window.identifier = NSUserInterfaceItemIdentifier("cmux.main")
            AppDelegate.shared?.attachUpdateAccessory(to: window)
        })
    }

    private func addTab() {
        tabManager.addTab()
        sidebarSelection = .tabs
    }

}

struct VerticalTabsSidebar: View {
    @EnvironmentObject var tabManager: TabManager
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabItemView(
                                tab: tab,
                                index: index,
                                selection: $selection,
                                selectedTabIds: $selectedTabIds,
                                lastSidebarSelectionIndex: $lastSidebarSelectionIndex
                            )
                        }
                    }
                    .padding(.vertical, 8)

                    SidebarEmptyArea(
                        selection: $selection,
                        selectedTabIds: $selectedTabIds,
                        lastSidebarSelectionIndex: $lastSidebarSelectionIndex
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .accessibilityIdentifier("Sidebar")
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

private struct SidebarEmptyArea: View {
    @EnvironmentObject var tabManager: TabManager
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture(count: 2) {
                tabManager.addTab()
                if let selectedId = tabManager.selectedTabId {
                    selectedTabIds = [selectedId]
                    lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
                }
                selection = .tabs
            }
    }
}

struct TabItemView: View {
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @ObservedObject var tab: Tab
    let index: Int
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @State private var isHovering = false

    var isActive: Bool {
        tabManager.selectedTabId == tab.id
    }

    var isMultiSelected: Bool {
        selectedTabIds.contains(tab.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                let unreadCount = notificationStore.unreadCount(forTabId: tab.id)
                if unreadCount > 0 {
                    ZStack {
                        Circle()
                            .fill(isActive ? Color.white.opacity(0.25) : Color.accentColor)
                        Text("\(unreadCount)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 16, height: 16)
                }

                Text(tab.title)
                    .font(.system(size: 12))
                    .foregroundColor(isActive ? .white : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Button(action: { tabManager.closeTab(tab) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(isActive ? .white.opacity(0.7) : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
                .opacity((isHovering || isActive || isMultiSelected) && tabManager.tabs.count > 1 ? 1 : 0)
                .allowsHitTesting((isHovering || isActive || isMultiSelected) && tabManager.tabs.count > 1)
            }

            if let subtitle = latestNotificationText {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(isActive ? .white.opacity(0.8) : .secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }

            if let directories = directorySummary {
                Text(directories)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(isActive ? .white.opacity(0.75) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            updateSelection()
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            let targetIds = contextTargetIds()
            Button("Close Tabs") {
                closeTabs(targetIds)
            }
            .disabled(targetIds.isEmpty)

            Button("Close Others") {
                closeOtherTabs(targetIds)
            }
            .disabled(tabManager.tabs.count <= 1 || targetIds.count == tabManager.tabs.count)

            Button("Close Tabs Below") {
                closeTabsBelow(tabId: tab.id)
            }
            .disabled(index >= tabManager.tabs.count - 1)

            Button("Close Tabs Above") {
                closeTabsAbove(tabId: tab.id)
            }
            .disabled(index == 0)

            Divider()

            Button("Move to Top") {
                tabManager.moveTabsToTop(Set(targetIds))
                syncSelectionAfterMutation()
            }
            .disabled(targetIds.isEmpty)

            Divider()

            Button("Mark as Read") {
                markTabsRead(targetIds)
            }
            .disabled(!hasUnreadNotifications(in: targetIds))

            Button("Mark as Unread") {
                markTabsUnread(targetIds)
            }
            .disabled(!hasReadNotifications(in: targetIds))
        }
    }

    private var backgroundColor: Color {
        if isActive {
            return Color.accentColor
        }
        if isMultiSelected {
            return Color.accentColor.opacity(0.25)
        }
        if isHovering {
            return Color(nsColor: .controlBackgroundColor).opacity(0.5)
        }
        return Color.clear
    }

    private func updateSelection() {
        let modifiers = NSEvent.modifierFlags
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)

        if isShift, let lastIndex = lastSidebarSelectionIndex {
            let lower = min(lastIndex, index)
            let upper = max(lastIndex, index)
            let rangeIds = tabManager.tabs[lower...upper].map { $0.id }
            if isCommand {
                selectedTabIds.formUnion(rangeIds)
            } else {
                selectedTabIds = Set(rangeIds)
            }
        } else if isCommand {
            if selectedTabIds.contains(tab.id) {
                selectedTabIds.remove(tab.id)
            } else {
                selectedTabIds.insert(tab.id)
            }
        } else {
            selectedTabIds = [tab.id]
        }

        lastSidebarSelectionIndex = index
        tabManager.selectTab(tab)
        selection = .tabs
    }

    private func contextTargetIds() -> [UUID] {
        let baseIds: Set<UUID> = selectedTabIds.contains(tab.id) ? selectedTabIds : [tab.id]
        return tabManager.tabs.compactMap { baseIds.contains($0.id) ? $0.id : nil }
    }

    private func closeTabs(_ targetIds: [UUID]) {
        for id in targetIds {
            if let tab = tabManager.tabs.first(where: { $0.id == id }) {
                tabManager.closeTab(tab)
            }
        }
        selectedTabIds.subtract(targetIds)
        syncSelectionAfterMutation()
    }

    private func closeOtherTabs(_ targetIds: [UUID]) {
        let keepIds = Set(targetIds)
        let idsToClose = tabManager.tabs.compactMap { keepIds.contains($0.id) ? nil : $0.id }
        closeTabs(idsToClose)
    }

    private func closeTabsBelow(tabId: UUID) {
        guard let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let idsToClose = tabManager.tabs.suffix(from: anchorIndex + 1).map { $0.id }
        closeTabs(idsToClose)
    }

    private func closeTabsAbove(tabId: UUID) {
        guard let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let idsToClose = tabManager.tabs.prefix(upTo: anchorIndex).map { $0.id }
        closeTabs(idsToClose)
    }

    private func markTabsRead(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.markRead(forTabId: id)
        }
    }

    private func markTabsUnread(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.markUnread(forTabId: id)
        }
    }

    private func hasUnreadNotifications(in targetIds: [UUID]) -> Bool {
        let targetSet = Set(targetIds)
        return notificationStore.notifications.contains { targetSet.contains($0.tabId) && !$0.isRead }
    }

    private func hasReadNotifications(in targetIds: [UUID]) -> Bool {
        let targetSet = Set(targetIds)
        return notificationStore.notifications.contains { targetSet.contains($0.tabId) && $0.isRead }
    }

    private func syncSelectionAfterMutation() {
        let existingIds = Set(tabManager.tabs.map { $0.id })
        selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
        if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
            selectedTabIds = [selectedId]
        }
        if let selectedId = tabManager.selectedTabId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
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
