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


// MARK: - Copy, paste, and menu item validation
extension GhosttyNSView {
    @IBAction func copy(_ sender: Any?) {
        _ = performBindingAction("copy_to_clipboard")
    }

    @IBAction func copyWorkspaceAndSurfaceIdentifiers(_ sender: Any?) {
        guard let terminalSurface else { return }
        let paneId = terminalSurface.owningWorkspace()?.paneId(forPanelId: terminalSurface.id)?.id
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeWorkspacePaneSurfaceIdentifiers(
                workspaceId: terminalSurface.tabId,
                paneId: paneId,
                surfaceId: terminalSurface.id,
                includeRefs: true
            )
        )
    }

    @IBAction func copyCurrentSurfaceLink(_ sender: Any?) {
        guard let terminalSurface else { return }
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspaceId: terminalSurface.tabId,
                surfaceId: terminalSurface.id
            )
        )
    }

    func recordDirectAgentHibernationTerminalInput() {
        guard let terminalSurface else { return }
        recordAgentHibernationTerminalInput(
            workspaceId: terminalSurface.tabId,
            panelId: terminalSurface.id
        )
    }

    // MARK: - Clipboard paste

    @IBAction func paste(_ sender: Any?) {
        guard prepareSurfaceForPaste(reason: "paste.missingSurface") else { return }
        recordDirectAgentHibernationTerminalInput()
        _ = performBindingAction("paste_from_clipboard")
    }

    /// Pastes clipboard text as plain text, stripping any rich formatting.
    @IBAction func pasteAsPlainText(_ sender: Any?) {
        guard prepareSurfaceForPaste(reason: "pasteAsPlainText.missingSurface") else { return }
        recordDirectAgentHibernationTerminalInput()
        _ = performBindingAction("paste_from_clipboard")
    }

    func applyConfiguredMenuShortcut(_ shortcut: StoredShortcut, to item: NSMenuItem) {
        guard let keyEquivalent = shortcut.menuItemKeyEquivalent else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }

        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = shortcut.modifierFlags
    }

    /// Validates whether edit menu items (copy, paste, split) should be enabled.
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            guard let surface = surface else { return false }
            return ghostty_surface_has_selection(surface)
        case #selector(paste(_:)):
            return GhosttyPasteboardHelper.hasString(for: GHOSTTY_CLIPBOARD_STANDARD)
        case #selector(pasteAsPlainText(_:)):
            return GhosttyPasteboardHelper.hasString(for: GHOSTTY_CLIPBOARD_STANDARD)
        case #selector(splitHorizontally(_:)), #selector(splitVertically(_:)):
            return canSplitCurrentSurface()
        case #selector(copyWorkspaceAndSurfaceIdentifiers(_:)):
            return terminalSurface != nil
        default:
            return true
        }
    }

    // MARK: - Accessibility

}
