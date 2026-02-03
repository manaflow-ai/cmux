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
    @State private var isResizerHovering = false
    @State private var isResizerDragging = false
    @State private var dragStartWidth: CGFloat = 0
    @State private var sidebarSelection: SidebarSelection = .tabs
    @State private var selectedTabIds: Set<UUID> = []
    @State private var lastSidebarSelectionIndex: Int? = nil
    private let sidebarHandleWidth: CGFloat = 6

    var body: some View {
        let minSize = uiTestWindowSize() ?? defaultMainWindowSize
        HStack(spacing: 0) {
            if sidebarState.isVisible {
                VerticalTabsSidebar(
                    selection: $sidebarSelection,
                    selectedTabIds: $selectedTabIds,
                    lastSidebarSelectionIndex: $lastSidebarSelectionIndex
                )
                .frame(minWidth: sidebarWidth, maxWidth: sidebarWidth)
                .layoutPriority(1)
                .overlay(alignment: .trailing) {
                    SidebarResizerHandle(
                        accessibilityIdentifier: "SidebarResizer",
                        onDragStart: {
                            if !isResizerDragging {
                                isResizerDragging = true
                                dragStartWidth = sidebarWidth
                                if !isResizerHovering {
                                    NSCursor.resizeLeftRight.push()
                                    isResizerHovering = true
                                }
                            }
                        },
                        onDrag: { deltaX in
                            guard isResizerDragging else { return }
                            let nextWidth = clampSidebarWidth(dragStartWidth + deltaX)
                            withTransaction(Transaction(animation: nil)) {
                                sidebarWidth = nextWidth
                            }
                        },
                        onDragEnd: { deltaX in
                            guard isResizerDragging else { return }
                            isResizerDragging = false
                            if !isResizerHovering {
                                NSCursor.pop()
                            }
                            let finalWidth = clampSidebarWidth(dragStartWidth + deltaX)
                            withTransaction(Transaction(animation: nil)) {
                                sidebarWidth = finalWidth
                            }
                        }
                    )
                        .frame(width: sidebarHandleWidth)
                        .contentShape(Rectangle())
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
                }
            }

            terminalContent
                .layoutPriority(0)
        }
        .frame(minWidth: minSize.width, minHeight: minSize.height)
        .background(Color.clear)
        .sheet(isPresented: $tabManager.isSessionPickerPresented) {
            SessionPickerView()
                .environmentObject(tabManager)
        }
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
        .background(WindowAccessor { window in
            window.identifier = NSUserInterfaceItemIdentifier("cmux.main")
            AppDelegate.shared?.attachUpdateAccessory(to: window)
            AppDelegate.shared?.applyWindowDecorations(to: window)
            applyWindowMinSize(to: window)
            applyUITestWindowSize(to: window)
            applyUITestWindowResizes(to: window)
        })
    }

    private func addTab() {
        tabManager.beginNewTabFlow()
        sidebarSelection = .tabs
    }

    private func clampSidebarWidth(_ width: CGFloat) -> CGFloat {
        max(140, min(360, width))
    }
}

private func applyWindowMinSize(to window: NSWindow) {
    guard window.identifier?.rawValue == "cmux.main" else { return }
    let size = uiTestWindowSize() ?? defaultMainWindowSize
    window.contentMinSize = size
}

private func applyUITestWindowSize(to window: NSWindow) {
    guard window.identifier?.rawValue == "cmux.main" else { return }
    guard let size = uiTestWindowSize() else { return }
    let windowId = ObjectIdentifier(window)
    if uiTestSizedWindows.contains(windowId) {
        return
    }
    uiTestSizedWindows.insert(windowId)
    window.isRestorable = false
    window.contentMinSize = size
    let delays: [TimeInterval] = [0.0, 0.2, 0.5, 1.0]
    for delay in delays {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            window.setContentSize(size)
        }
    }
}

private func applyUITestWindowResizes(to window: NSWindow) {
    guard window.identifier?.rawValue == "cmux.main" else { return }
    guard let sizes = uiTestWindowSizes(), !sizes.isEmpty else { return }
    let windowId = ObjectIdentifier(window)
    if uiTestResizedWindows.contains(windowId) {
        return
    }
    uiTestResizedWindows.insert(windowId)
    for (index, size) in sizes.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.25) {
            window.setContentSize(size)
        }
    }
}

private func uiTestWindowSize() -> CGSize? {
    guard let raw = ProcessInfo.processInfo.environment["CMUX_UI_TEST_WINDOW_SIZE"],
          !raw.isEmpty else { return nil }
    let parts = raw.split { $0 == "x" || $0 == "," }
    guard parts.count >= 2,
          let width = Double(parts[0].trimmingCharacters(in: .whitespaces)),
          let height = Double(parts[1].trimmingCharacters(in: .whitespaces)),
          width > 0,
          height > 0 else { return nil }
    return CGSize(width: width, height: height)
}

private func uiTestWindowSizes() -> [CGSize]? {
    guard let raw = ProcessInfo.processInfo.environment["CMUX_UI_TEST_WINDOW_SIZES"],
          !raw.isEmpty else { return nil }
    let entries = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    var sizes: [CGSize] = []
    for entry in entries where !entry.isEmpty {
        let parts = entry.split { $0 == "x" || $0 == "," }
        guard parts.count >= 2,
              let width = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let height = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              width > 0,
              height > 0 else { continue }
        sizes.append(CGSize(width: width, height: height))
    }
    return sizes.isEmpty ? nil : sizes
}

private let defaultMainWindowSize = CGSize(width: 800, height: 600)
private var uiTestSizedWindows = Set<ObjectIdentifier>()
private var uiTestResizedWindows = Set<ObjectIdentifier>()

private extension ContentView {
    @ViewBuilder
    var terminalContent: some View {
        // Terminal Content - use ZStack to keep all surfaces alive
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(tabManager.tabs) { tab in
                    let isActive = tabManager.selectedTabId == tab.id
                    TerminalSplitTreeView(
                        tab: tab,
                        isTabActive: isActive,
                        isResizing: isResizerDragging
                    )
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(sidebarSelection == .tabs ? 1 : 0)
            .allowsHitTesting(sidebarSelection == .tabs)

            NotificationsPage(selection: $sidebarSelection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(sidebarSelection == .notifications ? 1 : 0)
                .allowsHitTesting(sidebarSelection == .notifications)
        }
    }

}

private struct SidebarResizerHandle: NSViewRepresentable {
    var accessibilityIdentifier: String
    var onDragStart: () -> Void
    var onDrag: (CGFloat) -> Void
    var onDragEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> SidebarResizerNSView {
        let view = SidebarResizerNSView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityIdentifier(accessibilityIdentifier)
        view.onDragStart = onDragStart
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
        return view
    }

    func updateNSView(_ nsView: SidebarResizerNSView, context: Context) {
        nsView.setAccessibilityElement(true)
        nsView.setAccessibilityRole(.group)
        nsView.setAccessibilityIdentifier(accessibilityIdentifier)
        nsView.onDragStart = onDragStart
        nsView.onDrag = onDrag
        nsView.onDragEnd = onDragEnd
    }
}

private final class SidebarResizerNSView: NSView {
    var onDragStart: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: ((CGFloat) -> Void)?
    private var dragStartX: CGFloat?
    private var isDragging = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isDragging = true
        dragStartX = event.locationInWindow.x
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let dragStartX else { return }
        let deltaX = event.locationInWindow.x - dragStartX
        onDrag?(deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging, let dragStartX else { return }
        let deltaX = event.locationInWindow.x - dragStartX
        isDragging = false
        onDragEnd?(deltaX)
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
                tabManager.beginNewTabFlow()
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

struct SessionPickerView: View {
    @EnvironmentObject var tabManager: TabManager
    @State private var selectedConnectionId: String = ""
    @State private var sessions: [CmuxdSessionInfo] = []
    @State private var selectedSessionId: String? = nil
    @State private var isLoading = false
    @State private var sessionListRequestId: Int = 0

    private var connections: [CmuxdConnection] {
        CmuxdManager.shared.connections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remote Sessions")
                .font(.headline)

            if connections.isEmpty {
                Text("No remote connections configured.")
                    .foregroundColor(.secondary)
            } else {
                Picker("Connection", selection: $selectedConnectionId) {
                    ForEach(connections, id: \.id) { connection in
                        Text(connection.label).tag(connection.id)
                    }
                }
                .pickerStyle(.menu)

                if isLoading {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                List(sessions) { session in
                    let isSelected = selectedSessionId == session.id
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title.isEmpty ? String(session.id.prefix(8)) : session.title)
                                .font(.body)
                            if !session.cwd.isEmpty {
                                Text(session.cwd)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                    .onTapGesture {
                        selectedSessionId = session.id
                    }
                }
                .frame(minHeight: 200)
            }

            HStack {
                Button("Cancel") {
                    tabManager.isSessionPickerPresented = false
                }

                Spacer()

                Button("New Session") {
                    createNewSession()
                }
                .disabled(selectedConnectionId.isEmpty)

                Button("Attach") {
                    attachSelectedSession()
                }
                .disabled(selectedSessionId == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 320)
        .onAppear {
            if selectedConnectionId.isEmpty {
                selectedConnectionId = CmuxdManager.shared.defaultConnectionId ?? connections.first?.id ?? ""
            }
            loadSessions()
        }
        .onChange(of: selectedConnectionId) { _ in
            selectedSessionId = nil
            loadSessions()
        }
    }

    private func loadSessions() {
        guard !selectedConnectionId.isEmpty,
              let connection = CmuxdManager.shared.connection(for: selectedConnectionId) else {
            sessions = []
            isLoading = false
            return
        }
        sessionListRequestId += 1
        let requestId = sessionListRequestId
        let requestedConnectionId = selectedConnectionId
        isLoading = true
        connection.fetchSessionList { list in
            guard requestId == sessionListRequestId,
                  requestedConnectionId == selectedConnectionId else {
                return
            }
            sessions = list
            if selectedSessionId != nil, sessions.contains(where: { $0.id == selectedSessionId }) == false {
                selectedSessionId = nil
            }
            isLoading = false
        }
    }

    private func createNewSession() {
        guard !selectedConnectionId.isEmpty else { return }
        let ref = CmuxdSessionRef(connectionId: selectedConnectionId, sessionId: nil, paneId: nil)
        _ = tabManager.addTab(sessionRef: ref)
        tabManager.isSessionPickerPresented = false
    }

    private func attachSelectedSession() {
        guard let sessionId = selectedSessionId else { return }
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
        let ref = CmuxdSessionRef(connectionId: selectedConnectionId, sessionId: session.id, paneId: session.paneId)
        _ = tabManager.addTab(sessionRef: ref)
        tabManager.isSessionPickerPresented = false
    }
}
