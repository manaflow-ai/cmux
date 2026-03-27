import AppKit
import Bonsplit

// MARK: - Action Methods & Helpers

extension SidebarContextMenuController {

    // MARK: - Rename Dialog

    func promptRename() {
        guard let workspace, let tabManager else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.renameWorkspace.title", defaultValue: "Rename Workspace")
        alert.informativeText = String(localized: "alert.renameWorkspace.message", defaultValue: "Enter a custom name for this workspace.")
        let input = NSTextField(string: workspace.customTitle ?? workspace.title)
        input.placeholderString = String(localized: "alert.renameWorkspace.placeholder", defaultValue: "Workspace name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        tabManager.setCustomTitle(tabId: workspace.id, title: input.stringValue)
    }

    // MARK: - Custom Color Dialog

    func promptCustomColor(targetIds: [UUID]) {
        guard let workspace, let tabManager else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.customColor.title", defaultValue: "Custom Workspace Color")
        alert.informativeText = String(localized: "alert.customColor.message", defaultValue: "Enter a hex color in the format #RRGGBB.")
        let seed = workspace.customColor ?? WorkspaceTabColorSettings.customColors().first ?? ""
        let input = NSTextField(string: seed)
        input.placeholderString = "#1565C0"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.customColor.apply", defaultValue: "Apply"))
        alert.addButton(withTitle: String(localized: "alert.customColor.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        guard let normalized = WorkspaceTabColorSettings.addCustomColor(input.stringValue) else {
            showInvalidColorAlert(input.stringValue)
            return
        }
        for id in targetIds { tabManager.setTabColor(tabId: id, color: normalized) }
    }

    private func showInvalidColorAlert(_ value: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "alert.invalidColor.title", defaultValue: "Invalid Color")
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            alert.informativeText = String(localized: "alert.invalidColor.emptyMessage", defaultValue: "Enter a hex color in the format #RRGGBB.")
        } else {
            alert.informativeText = String(localized: "alert.invalidColor.invalidMessage", defaultValue: "\"\(trimmed)\" is not a valid hex color. Use #RRGGBB.")
        }
        alert.addButton(withTitle: String(localized: "alert.invalidColor.ok", defaultValue: "OK"))
        _ = alert.runModal()
    }

    // MARK: - Move Helpers

    func moveBy(_ delta: Int) {
        guard let workspace, let tabManager else { return }
        let targetIndex = index + delta
        guard targetIndex >= 0, targetIndex < tabManager.tabs.count else { return }
        guard tabManager.reorderWorkspace(tabId: workspace.id, toIndex: targetIndex) else { return }
        writeSelectedTabIds([workspace.id])
        writeLastSidebarSelectionIndex(tabManager.tabs.firstIndex { $0.id == workspace.id })
        tabManager.selectTab(workspace)
        setSelectionToTabs?()
    }

    func moveWorkspacesToNewWindow(_ workspaceIds: [UUID]) {
        guard let app = AppDelegate.shared, let tabManager else { return }
        let ordered = tabManager.tabs.compactMap { workspaceIds.contains($0.id) ? $0.id : nil }
        guard let firstId = ordered.first else { return }
        let focusNow = ordered.count == 1
        guard let newWindowId = app.moveWorkspaceToNewWindow(workspaceId: firstId, focus: focusNow) else { return }
        if ordered.count > 1 {
            for id in ordered.dropFirst() {
                _ = app.moveWorkspaceToWindow(workspaceId: id, windowId: newWindowId, focus: false)
            }
            if let lastId = ordered.last {
                _ = app.moveWorkspaceToWindow(workspaceId: lastId, windowId: newWindowId, focus: true)
            }
        }
        var sel = readSelectedTabIds()
        sel.subtract(ordered)
        writeSelectedTabIds(sel)
        syncSelectionAfterMutation()
    }

    func moveWorkspaces(_ workspaceIds: [UUID], toWindow windowId: UUID) {
        guard let app = AppDelegate.shared, let tabManager else { return }
        let ordered = tabManager.tabs.compactMap { workspaceIds.contains($0.id) ? $0.id : nil }
        for (i, id) in ordered.enumerated() {
            _ = app.moveWorkspaceToWindow(workspaceId: id, windowId: windowId, focus: i == ordered.count - 1)
        }
        var sel = readSelectedTabIds()
        sel.subtract(ordered)
        writeSelectedTabIds(sel)
        syncSelectionAfterMutation()
    }

    // MARK: - Selection Sync

    func syncSelectionAfterMutation() {
        guard let tabManager else { return }
        let existingIds = Set(tabManager.tabs.map(\.id))
        var sel = readSelectedTabIds().filter { existingIds.contains($0) }
        if sel.isEmpty, let selectedId = tabManager.selectedTabId {
            sel = [selectedId]
        }
        writeSelectedTabIds(sel)
        if let selectedId = tabManager.selectedTabId {
            writeLastSidebarSelectionIndex(tabManager.tabs.firstIndex { $0.id == selectedId })
        }
    }

    // MARK: - Hierarchy Check

    func computeCanMakeChild() -> Bool {
        guard let workspace, let tabManager else { return false }
        let currentDepth = tabManager.groupManager.depthOf(workspaceId: workspace.id)
        guard currentDepth < 3 else { return false }
        if currentDepth <= 1 {
            guard let idx = tabManager.groupManager.items.firstIndex(of: workspace.id),
                  idx > 0 else { return false }
        } else {
            guard let parent = tabManager.groupManager.parentWorkspace(of: workspace.id),
                  let idx = parent.childWorkspaceIds.firstIndex(of: workspace.id),
                  idx > 0 else { return false }
        }
        return true
    }

    // MARK: - SSH Error

    func copyableSSHError(for workspace: Workspace) -> String? {
        let fallbackTarget = workspace.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback", defaultValue: "remote host")
        let trimmedDetail = workspace.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if workspace.remoteConnectionState == .error, let trimmedDetail, !trimmedDetail.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: workspace.title, target: fallbackTarget, detail: trimmedDetail)
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        if let statusValue = workspace.statusEntries["remote.error"]?.value
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !statusValue.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: workspace.title, target: fallbackTarget, detail: statusValue)
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        return nil
    }

    // MARK: - Color Swatch

    func colorSwatchImage(hex: String) -> NSImage {
        let color = NSColor(hex: hex) ?? .gray
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
