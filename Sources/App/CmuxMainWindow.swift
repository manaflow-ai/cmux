import AppKit
import SwiftUI

final class MainWindowHostingView<Content: View>: NSHostingView<Content> {
    private let zeroSafeAreaLayoutGuide = NSLayoutGuide()

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var safeAreaRect: NSRect { bounds }
    override var safeAreaLayoutGuide: NSLayoutGuide { zeroSafeAreaLayoutGuide }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        addLayoutGuide(zeroSafeAreaLayoutGuide)
        NSLayoutConstraint.activate([
            zeroSafeAreaLayoutGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            zeroSafeAreaLayoutGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            zeroSafeAreaLayoutGuide.topAnchor.constraint(equalTo: topAnchor),
            zeroSafeAreaLayoutGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    deinit {}

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class CmuxMainWindow: NSWindow {
    weak var workspaceDockTitlebarLayout: WorkspaceDockLayout?

    private var isSoftHiddenForVisibilityController = false
    private let workspaceDockTitlebarControlSize = NSSize(width: 76, height: 40)
    private let workspaceDockTitlebarTrailingInset: CGFloat = 6

    func setSoftHiddenForVisibilityController(_ isSoftHidden: Bool) {
        isSoftHiddenForVisibilityController = isSoftHidden
        if isSoftHidden {
            makeFirstResponder(nil)
            ignoresMouseEvents = true
            alphaValue = 0
        } else {
            alphaValue = 1
            ignoresMouseEvents = false
        }
    }

    override func sendEvent(_ event: NSEvent) {
        guard !isSoftHiddenForVisibilityController else { return }
        if handleWorkspaceDockTitlebarEvent(event) {
            return
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        guard !isSoftHiddenForVisibilityController else { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        guard !isSoftHiddenForVisibilityController else { return }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard !isSoftHiddenForVisibilityController else { return }
        super.flagsChanged(with: event)
    }

    private func handleWorkspaceDockTitlebarEvent(_ event: NSEvent) -> Bool {
        guard let layout = workspaceDockTitlebarLayout,
              event.window === self,
              let edge = workspaceDockTitlebarEdge(at: event.locationInWindow) else {
            return false
        }

        switch event.type {
        case .leftMouseDown:
            if event.modifierFlags.contains(.control) {
                showWorkspaceDockTitlebarMenu(edge: edge, layout: layout, event: event)
            } else {
                layout.toggleEdge(edge)
            }
            return true
        case .rightMouseDown, .otherMouseDown:
            showWorkspaceDockTitlebarMenu(edge: edge, layout: layout, event: event)
            return true
        default:
            return false
        }
    }

    private func workspaceDockTitlebarEdge(at point: NSPoint) -> WorkspaceDockEdge? {
        let rect = NSRect(
            x: frame.width - workspaceDockTitlebarControlSize.width - workspaceDockTitlebarTrailingInset,
            y: frame.height - workspaceDockTitlebarControlSize.height,
            width: workspaceDockTitlebarControlSize.width,
            height: workspaceDockTitlebarControlSize.height
        )
        guard rect.contains(point) else { return nil }

        let edges = WorkspaceDockEdge.controlOrder
        guard !edges.isEmpty else { return nil }
        let segmentWidth = rect.width / CGFloat(edges.count)
        let rawIndex = Int((point.x - rect.minX) / max(1, segmentWidth))
        let index = min(max(0, rawIndex), edges.count - 1)
        return edges[index]
    }

    private func showWorkspaceDockTitlebarMenu(
        edge: WorkspaceDockEdge,
        layout: WorkspaceDockLayout,
        event: NSEvent
    ) {
        guard let contentView else { return }
        let menu = workspaceDockTitlebarMenu(edge: edge, layout: layout)
        NSMenu.popUpContextMenu(menu, with: event, for: contentView)
    }

    private func workspaceDockTitlebarMenu(edge: WorkspaceDockEdge, layout: WorkspaceDockLayout) -> NSMenu {
        let menu = NSMenu()
        addWorkspaceDockTitlebarMenuItem(
            to: menu,
            title: layout.isEdgeOpen(edge)
                ? workspaceDockTitlebarCloseTitle(edge: edge)
                : workspaceDockTitlebarOpenTitle(edge: edge),
            command: .toggle(edge)
        )

        let countItem = NSMenuItem(
            title: String(localized: "workspaceDock.count.menu", defaultValue: "Dock Count"),
            action: nil,
            keyEquivalent: ""
        )
        let countMenu = NSMenu()
        for count in layout.dockCountChoices(for: edge) {
            let item = workspaceDockTitlebarMenuItem(
                title: "\(count)",
                command: .setCount(edge, count)
            )
            item.isEnabled = layout.canSetDockCount(edge: edge, count: count)
            countMenu.addItem(item)
        }
        countItem.submenu = countMenu
        menu.addItem(countItem)

        if layout.hasEmptyDocks(edge: edge) {
            menu.addItem(.separator())
            addWorkspaceDockTitlebarMenuItem(
                to: menu,
                title: workspaceDockTitlebarRemoveEmptyDocksTitle(edge: edge),
                command: .removeEmpty(edge)
            )
        }

        return menu
    }

    private func addWorkspaceDockTitlebarMenuItem(to menu: NSMenu, title: String, command: WorkspaceDockTitlebarMenuCommand) {
        menu.addItem(workspaceDockTitlebarMenuItem(title: title, command: command))
    }

    private func workspaceDockTitlebarMenuItem(title: String, command: WorkspaceDockTitlebarMenuCommand) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performWorkspaceDockTitlebarMenuCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command
        return item
    }

    @objc private func performWorkspaceDockTitlebarMenuCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? WorkspaceDockTitlebarMenuCommand,
              let layout = workspaceDockTitlebarLayout else {
            return
        }

        switch command {
        case .toggle(let edge):
            layout.toggleEdge(edge)
        case .setCount(let edge, let count):
            layout.setDockCount(edge: edge, count: count)
        case .removeEmpty(let edge):
            layout.removeEmptyDocks(edge: edge)
        }
    }

    private func workspaceDockTitlebarOpenTitle(edge: WorkspaceDockEdge) -> String {
        switch edge {
        case .left:
            return String(localized: "workspaceDock.open.left", defaultValue: "Open Left Dock")
        case .right:
            return String(localized: "workspaceDock.open.right", defaultValue: "Open Right Dock")
        case .bottom:
            return String(localized: "workspaceDock.open.bottom", defaultValue: "Open Bottom Dock")
        }
    }

    private func workspaceDockTitlebarCloseTitle(edge: WorkspaceDockEdge) -> String {
        switch edge {
        case .left:
            return String(localized: "workspaceDock.close.left", defaultValue: "Close Left Dock")
        case .right:
            return String(localized: "workspaceDock.close.right", defaultValue: "Close Right Dock")
        case .bottom:
            return String(localized: "workspaceDock.close.bottom", defaultValue: "Close Bottom Dock")
        }
    }

    private func workspaceDockTitlebarRemoveEmptyDocksTitle(edge: WorkspaceDockEdge) -> String {
        switch edge {
        case .left:
            return String(localized: "workspaceDock.removeEmpty.left", defaultValue: "Remove Empty Left Docks")
        case .right:
            return String(localized: "workspaceDock.removeEmpty.right", defaultValue: "Remove Empty Right Docks")
        case .bottom:
            return String(localized: "workspaceDock.removeEmpty.bottom", defaultValue: "Remove Empty Bottom Docks")
        }
    }

    private enum WorkspaceDockTitlebarMenuCommand {
        case toggle(WorkspaceDockEdge)
        case setCount(WorkspaceDockEdge, Int)
        case removeEmpty(WorkspaceDockEdge)
    }
}

extension CmuxMainWindow {
    private static let defaultContentSize = NSSize(width: 1_000, height: 700)

    /// Returns an unpositioned content rect clamped to the visible display; callers own final placement.
    static func defaultContentRect(styleMask: NSWindow.StyleMask) -> NSRect {
        let unpositionedContentRect = NSRect(origin: .zero, size: defaultContentSize)
        guard let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            return unpositionedContentRect
        }

        let frameRect = NSWindow.frameRect(forContentRect: unpositionedContentRect, styleMask: styleMask)
        let clampedFrameRect = clampedFrame(frameRect, within: visibleFrame)
        return NSWindow.contentRect(forFrameRect: clampedFrameRect, styleMask: styleMask)
    }

    private static func clampedFrame(_ frame: NSRect, within visibleFrame: NSRect) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }

        let width = min(max(frame.width, defaultContentSize.width), visibleFrame.width)
        let height = min(max(frame.height, defaultContentSize.height), visibleFrame.height)
        return NSRect(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height),
            width: width,
            height: height
        )
    }
}
