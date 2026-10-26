import CmuxNextActions
import CmuxNextPalette
import CmuxNextSidebar
import Foundation

// The Archived page of auto-archive (plans/cmux-next/auto-archive-DESIGN.md "Archived view"): every
// archived workspace with Restore and Open, searchable by name, and Restore All.
extension AutoArchiveCoordinator {
    /// Show Archived Workspaces: one row per archived workspace (newest use first). Return restores
    /// it; the row's Open shows it as it is (dimmed). `open` shows workspace `id` in the window.
    func archivedPage(open: @escaping @MainActor (String) -> Void) -> PalettePageSpec {
        // Reloads after each Restore (performKeepingOpen), so a restored row leaves the list.
        let provider = AsyncPaletteProvider(id: "autoArchive.archived") { [weak self] in self?.archivedItems(open: open) ?? [] }
        return PalettePageSpec(id: "autoArchive.archived", title: AutoArchiveStrings.archivedTitle,
                               placeholder: AutoArchiveStrings.archivedPlaceholder, symbol: "archivebox", providers: [provider])
    }

    func archivedItems(open: @escaping @MainActor (String) -> Void) -> [PaletteItem] {
        let rows = archivedWorkspaces()
        guard !rows.isEmpty else { return [] }
        let formatter = RelativeDateTimeFormatter()
        let time = Date()
        var items = rows.map { row in
            PaletteItem(
                id: "archived:\(row.item)", title: row.title.isEmpty ? row.workspace : row.title,
                accessory: row.lastActive.map { formatter.localizedString(for: $0, relativeTo: time) }, symbol: "archivebox",
                keywords: [row.workspace],
                primary: PaletteCommand(id: "restore", title: AutoArchiveStrings.restore, symbol: "arrow.uturn.backward",
                                        effect: .performKeepingOpen { [weak self] in self?.restore([row.item]) }),
                secondary: [PaletteCommand(id: "open", title: AutoArchiveStrings.open, symbol: "arrow.right.circle",
                                           effect: .perform { open(row.workspace) })])
        }
        let all = rows.map(\.item)
        items.append(PaletteItem(
            id: "archived:all", title: AutoArchiveStrings.restoreAll, symbol: "arrow.uturn.backward.circle",
            primary: PaletteCommand(id: "restoreAll", title: AutoArchiveStrings.restoreAll, symbol: "arrow.uturn.backward",
                                    effect: .perform { [weak self] in self?.restore(all) })))
        return items
    }
}

extension AppServices {
    /// Show Archived Workspaces: the Archived page over the active window.
    func showArchivedWorkspaces() {
        palette.show(page: autoArchive.archivedPage(open: { [weak self] in self?.openArchived($0) }), relativeTo: windows.active?.window)
    }

    /// Shows workspace `id` from the Archived page: in the active window, else its own.
    private func openArchived(_ id: String) {
        if let window = windows.active {
            windows.show(workspaceID: id, in: window.state)
        } else {
            _ = windows.reveal(workspaceID: id)
        }
    }

    /// The document item of the invocation's group (Auto-Archive Group Workspaces).
    func autoArchiveGroupItem(_ invocation: ActionInvocation) throws -> String {
        let id = try archiveGroupID(invocation)
        return SidebarDocStore.current?.records.groupItem(personal: id) ?? id
    }
}
