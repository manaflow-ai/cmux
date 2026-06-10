import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers


// MARK: - Context menu and split actions
extension GhosttyNSView {
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let surface = surface else { return nil }
        if ghostty_surface_mouse_captured(surface) {
            return nil
        }

        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))

        let menu = NSMenu()
        if onTriggerFlash != nil {
            let flashItem = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.triggerFlash", defaultValue: "Trigger Flash"),
                action: #selector(triggerFlash(_:)),
                keyEquivalent: ""
            )
            flashItem.target = self
            menu.addItem(.separator())
        }
        if ghostty_surface_has_selection(surface) {
            let item = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.copy", defaultValue: "Copy"),
                action: #selector(copy(_:)),
                keyEquivalent: ""
            )
            item.target = self
        }
        let pasteItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.paste", defaultValue: "Paste"),
            action: #selector(paste(_:)),
            keyEquivalent: ""
        )
        pasteItem.target = self
        menu.addItem(.separator())
        let splitHorizontallyItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.splitHorizontally", defaultValue: "Split Horizontally"),
            action: #selector(splitHorizontally(_:)),
            keyEquivalent: ""
        )
        splitHorizontallyItem.target = self
        applyConfiguredMenuShortcut(KeyboardShortcutSettings.menuShortcut(for: .splitDown), to: splitHorizontallyItem)
        splitHorizontallyItem.image = NSImage(
            systemSymbolName: "rectangle.bottomhalf.inset.filled",
            accessibilityDescription: nil
        )

        let splitVerticallyItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.splitVertically", defaultValue: "Split Vertically"),
            action: #selector(splitVertically(_:)),
            keyEquivalent: ""
        )
        splitVerticallyItem.target = self
        applyConfiguredMenuShortcut(KeyboardShortcutSettings.menuShortcut(for: .splitRight), to: splitVerticallyItem)
        splitVerticallyItem.image = NSImage(
            systemSymbolName: "rectangle.righthalf.inset.filled",
            accessibilityDescription: nil
        )
        appendMoveCurrentSurfaceMoveMenuItems(to: menu); menu.addItem(.separator())
        let resetTerminalItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.resetTerminal", defaultValue: "Reset Terminal"),
            action: #selector(resetTerminal(_:)),
            keyEquivalent: ""
        )
        resetTerminalItem.target = self
        resetTerminalItem.image = NSImage(
            systemSymbolName: "arrow.trianglehead.2.clockwise",
            accessibilityDescription: nil
        )
        if terminalSurface != nil {
            menu.addItem(.separator())
            let identifiersItem = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.copyIdentifiers", defaultValue: "Copy IDs"),
                action: #selector(copyWorkspaceAndSurfaceIdentifiers(_:)),
                keyEquivalent: ""
            )
            identifiersItem.target = self
            let linkItem = menu.addItem(
                withTitle: String(localized: "command.copySurfaceLink.title", defaultValue: "Copy Surface Link"),
                action: #selector(copyCurrentSurfaceLink(_:)),
                keyEquivalent: ""
            )
            linkItem.target = self
        }
        return menu
    }

    func canSplitCurrentSurface() -> Bool {
        guard let tabId,
              let surfaceId = terminalSurface?.id,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: tabId) ?? app.tabManager,
              let workspace = manager.tabs.first(where: { $0.id == tabId }) else {
            return false
        }
        return workspace.panels[surfaceId] != nil
    }

    @objc func splitHorizontally(_ sender: Any?) {
        _ = splitCurrentSurface(direction: .down)
    }

    @objc func splitVertically(_ sender: Any?) {
        _ = splitCurrentSurface(direction: .right)
    }

    @discardableResult
    private func splitCurrentSurface(direction: SplitDirection) -> Bool {
        guard let tabId,
              let surfaceId = terminalSurface?.id,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: tabId) ?? app.tabManager else {
            return false
        }
        return manager.createSplit(tabId: tabId, surfaceId: surfaceId, direction: direction) != nil
    }

    @objc private func triggerFlash(_ sender: Any?) {
        onTriggerFlash?()
    }

    @objc private func resetTerminal(_ sender: Any?) {
        _ = performBindingAction("reset")
    }

}
