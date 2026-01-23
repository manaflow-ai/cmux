import AppKit
import SwiftUI
import Foundation

class Tab: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var currentDirectory: String
    let terminalSurface: TerminalSurface

    init(title: String = "Terminal") {
        self.id = UUID()
        self.title = title
        self.currentDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        self.terminalSurface = TerminalSurface(tabId: id)
    }
}

class TabManager: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var selectedTabId: UUID?
    private var observers: [NSObjectProtocol] = []

    init() {
        addTab()
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let title = notification.userInfo?[GhosttyNotificationKey.title] as? String else { return }
            self.updateTabTitle(tabId: tabId, title: title)
        })
    }

    func addTab() {
        let newTab = Tab(title: "Terminal \(tabs.count + 1)")
        tabs.append(newTab)
        selectedTabId = newTab.id
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: newTab.id]
        )
    }

    func closeTab(_ tab: Tab) {
        guard tabs.count > 1 else { return }

        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.remove(at: index)

            if selectedTabId == tab.id {
                if index > 0 {
                    selectedTabId = tabs[index - 1].id
                } else {
                    selectedTabId = tabs.first?.id
                }
            }
        }
    }

    func closeCurrentTab() {
        guard let selectedId = selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedId }) else { return }
        closeTab(tab)
    }

    func selectTab(_ tab: Tab) {
        selectedTabId = tab.id
    }

    func titleForTab(_ tabId: UUID) -> String? {
        tabs.first(where: { $0.id == tabId })?.title
    }

    private func updateTabTitle(tabId: UUID, title: String) {
        guard !title.isEmpty else { return }
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        if tabs[index].title != title {
            tabs[index].title = title
        }
    }

    func focusTab(_ tabId: UUID) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        selectedTabId = tabId
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: tabId]
        )

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.unhide(nil)
            if let window = NSApp.keyWindow ?? NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func selectNextTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        selectedTabId = tabs[nextIndex].id
    }

    func selectPreviousTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = (currentIndex - 1 + tabs.count) % tabs.count
        selectedTabId = tabs[prevIndex].id
    }

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        selectedTabId = tabs[index].id
    }
}

extension Notification.Name {
    static let ghosttyDidSetTitle = Notification.Name("ghosttyDidSetTitle")
    static let ghosttyDidFocusTab = Notification.Name("ghosttyDidFocusTab")
}
