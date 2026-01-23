import AppKit
import SwiftUI
import Foundation

class Tab: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var currentDirectory: String
    @Published var splitTree: SplitTree<TerminalSurface>
    @Published var focusedSurfaceId: UUID?
    var splitViewSize: CGSize = .zero

    init(title: String = "Terminal") {
        self.id = UUID()
        self.title = title
        self.currentDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let surface = TerminalSurface(tabId: id, context: GHOSTTY_SURFACE_CONTEXT_TAB, configTemplate: nil)
        self.splitTree = SplitTree(view: surface)
        self.focusedSurfaceId = surface.id
    }

    var focusedSurface: TerminalSurface? {
        guard let focusedSurfaceId else { return nil }
        return surface(for: focusedSurfaceId)
    }

    func surface(for id: UUID) -> TerminalSurface? {
        guard let node = splitTree.root?.find(id: id) else { return nil }
        if case .leaf(let view) = node {
            return view
        }
        return nil
    }

    func focusSurface(_ id: UUID) {
        guard focusedSurfaceId != id else { return }
        focusedSurfaceId = id
    }

    func updateSplitViewSize(_ size: CGSize) {
        guard splitViewSize != size else { return }
        splitViewSize = size
    }

    func updateSplitRatio(node: SplitTree<TerminalSurface>.Node, ratio: Double) {
        do {
            splitTree = try splitTree.replacing(node: node, with: node.resizing(to: ratio))
        } catch {
            return
        }
    }

    func equalizeSplits() {
        splitTree = splitTree.equalized()
    }

    func newSplit(from surfaceId: UUID, direction: SplitTree<TerminalSurface>.NewDirection) -> TerminalSurface? {
        guard let targetSurface = surface(for: surfaceId) else { return nil }
        let inheritedConfig: ghostty_surface_config_s? = if let existing = targetSurface.surface {
            ghostty_surface_inherited_config(existing, GHOSTTY_SURFACE_CONTEXT_SPLIT)
        } else {
            nil
        }

        let newSurface = TerminalSurface(
            tabId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig
        )

        do {
            splitTree = try splitTree.inserting(view: newSurface, at: targetSurface, direction: direction)
            focusedSurfaceId = newSurface.id
            return newSurface
        } catch {
            return nil
        }
    }

    func moveFocus(from surfaceId: UUID, direction: SplitTree<TerminalSurface>.FocusDirection) -> Bool {
        guard let root = splitTree.root,
              let targetNode = root.find(id: surfaceId),
              let nextSurface = splitTree.focusTarget(for: direction, from: targetNode) else {
            return false
        }

        focusedSurfaceId = nextSurface.id
        return true
    }

    func resizeSplit(from surfaceId: UUID, direction: SplitTree<TerminalSurface>.Spatial.Direction, amount: UInt16) -> Bool {
        guard let root = splitTree.root,
              let targetNode = root.find(id: surfaceId),
              splitViewSize.width > 0,
              splitViewSize.height > 0 else {
            return false
        }

        do {
            splitTree = try splitTree.resizing(
                node: targetNode,
                by: amount,
                in: direction,
                with: CGRect(origin: .zero, size: splitViewSize)
            )
            return true
        } catch {
            return false
        }
    }

    func toggleZoom(on surfaceId: UUID) -> Bool {
        guard let root = splitTree.root,
              let targetNode = root.find(id: surfaceId) else {
            return false
        }

        guard splitTree.isSplit else { return false }

        if splitTree.zoomed == targetNode {
            splitTree = SplitTree(root: splitTree.root, zoomed: nil)
        } else {
            splitTree = SplitTree(root: splitTree.root, zoomed: targetNode)
        }
        return true
    }

    func closeSurface(_ surfaceId: UUID) -> Bool {
        guard let root = splitTree.root,
              let targetNode = root.find(id: surfaceId) else {
            return false
        }

        let shouldMoveFocus = focusedSurfaceId == surfaceId
        let nextFocus: TerminalSurface? = if shouldMoveFocus {
            if root.leftmostLeaf() === targetNode.leftmostLeaf() {
                splitTree.focusTarget(for: .next, from: targetNode)
            } else {
                splitTree.focusTarget(for: .previous, from: targetNode)
            }
        } else {
            nil
        }

        splitTree = splitTree.removing(targetNode)

        if splitTree.isEmpty {
            focusedSurfaceId = nil
            return true
        }

        if shouldMoveFocus {
            if let nextFocus {
                focusedSurfaceId = nextFocus.id
            } else {
                focusedSurfaceId = splitTree.root?.leftmostLeaf().id
            }
        }

        if !splitTree.isSplit {
            splitTree = SplitTree(root: splitTree.root, zoomed: nil)
        }

        return true
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

    func focusedSurfaceId(for tabId: UUID) -> UUID? {
        tabs.first(where: { $0.id == tabId })?.focusedSurfaceId
    }

    private func updateTabTitle(tabId: UUID, title: String) {
        guard !title.isEmpty else { return }
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        if tabs[index].title != title {
            tabs[index].title = title
        }
    }

    func focusTab(_ tabId: UUID, surfaceId: UUID? = nil) {
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

        if let surfaceId {
            focusSurface(tabId: tabId, surfaceId: surfaceId)
        }
    }

    func focusSurface(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.focusSurface(surfaceId)
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

    func newSplit(tabId: UUID, surfaceId: UUID, direction: SplitTree<TerminalSurface>.NewDirection) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.newSplit(from: surfaceId, direction: direction) != nil
    }

    func moveSplitFocus(tabId: UUID, surfaceId: UUID, direction: SplitTree<TerminalSurface>.FocusDirection) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.moveFocus(from: surfaceId, direction: direction)
    }

    func resizeSplit(tabId: UUID, surfaceId: UUID, direction: SplitTree<TerminalSurface>.Spatial.Direction, amount: UInt16) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.resizeSplit(from: surfaceId, direction: direction, amount: amount)
    }

    func equalizeSplits(tabId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        guard tab.splitTree.isSplit else { return false }
        tab.equalizeSplits()
        return true
    }

    func toggleSplitZoom(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.toggleZoom(on: surfaceId)
    }

    func closeSurface(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
        let tab = tabs[tabIndex]
        guard tab.closeSurface(surfaceId) else { return false }

        if tab.splitTree.isEmpty {
            if tabs.count > 1 {
                closeTab(tab)
            } else {
                let newSurface = TerminalSurface(
                    tabId: tab.id,
                    context: GHOSTTY_SURFACE_CONTEXT_TAB,
                    configTemplate: nil
                )
                tab.splitTree = SplitTree(view: newSurface)
                tab.focusSurface(newSurface.id)
            }
        }

        return true
    }
}

extension Notification.Name {
    static let ghosttyDidSetTitle = Notification.Name("ghosttyDidSetTitle")
    static let ghosttyDidFocusTab = Notification.Name("ghosttyDidFocusTab")
}
