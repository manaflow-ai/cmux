public import AppKit
import CmuxNextDesign
public import CmuxNextStash

/// The Stashed page's own side of its model: the title, the import notices (in this target's
/// string catalog) and the Undo toast of a delete.
extension StashPageModel {
    /// The Stashed page's title, for its top page and tab.
    public static var title: String { StashStrings.title }

    /// Delete Group (`tab` nil) or a row's ×. With `window`, the pages hide at once behind an
    /// Undo toast there and go for good when it ends without Undo; else they go now.
    public func delete(_ group: StashedGroup, tab: StashedGroup.Tab? = nil, undoIn window: NSWindow?) async {
        guard let window else {
            await delete(group, tab: tab)
            return
        }
        hide(group, tab: tab)
        let message = tab == nil ? StashStrings.deletedGroup : StashStrings.deletedTab
        let toast = CmuxToast(id: "stash.delete.\(group.id).\(tab?.id ?? "all")", message: message, action: .undo())
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        handle.onAction = { [weak self] in self?.unhide(group, tab: tab) }
        handle.onDismiss = { [weak self] reason in
            guard reason != .action, let self else { return }
            // task-owner: the model's op queue (`perform`) orders it; it ends with the delete.
            Task { @MainActor in
                await self.delete(group, tab: tab)
                self.unhide(group, tab: tab)
            }
        }
    }

    /// Imports `draft`'s pasted OneTab text. The box closes once pages were imported; with
    /// none, it stays open with the notice.
    public func importPasted(_ draft: StashImportDraft) async {
        let export = OneTabExport(parsing: draft.text)
        guard !export.groups.isEmpty else {
            showNotice(StashStrings.importNothing, error: true)
            return
        }
        await perform { [weak self] source in
            let (imported, skipped) = try await source.importGroups(export.groups)
            self?.showNotice(StashStrings.imported(imported, skipped: skipped), error: imported == 0)
            if imported > 0 { draft.close() }
        }
    }
}
