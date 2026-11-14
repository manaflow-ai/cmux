public import AppKit
import CmuxNextDesign

/// `contributes.menus`: the rows apps add to cmux's own right-click menus. A
/// menu reads them from the install mirror each time it opens, so a saved
/// manifest (`apps-changed`, which lists again) shows on the next right-click
/// with no relaunch.
extension AppsClient {
    /// One app's row in a menu.
    public struct MenuRow: Sendable, Hashable {
        public var app: String
        public var item: AppMenuItem
    }

    /// The rows visible apps (installed, enabled, not hidden) add to `target`'s menu: by
    /// `order` (unset last), then app id, then declaration order.
    public func menuRows(for target: AppMenuItem.Target) -> [MenuRow] {
        guard isListed else { return [] }
        let rows = apps.filter(\.isVisible).flatMap { app in
            app.manifest.menuItems.enumerated().filter { $0.element.target == target }.map { (app.id, $0.offset, $0.element) }
        }
        return rows.sorted { a, b in
            let (left, right) = (a.2.order ?? Int.max, b.2.order ?? Int.max)
            if left != right { return left < right }
            return a.0 != b.0 ? a.0 < b.0 : a.1 < b.1
        }.map { MenuRow(app: $0.0, item: $0.2) }
    }

    /// `target`'s app rows as menu items for a right-click on `kind` `id` (a workspace, tab or
    /// terminal). A click runs the row's op with the person's origin; a refusal goes to the app's log.
    public func menuItems(for target: AppMenuItem.Target, kind: String, id: String) -> [NSMenuItem] {
        menuRows(for: target).map { row in
            let click = MenuClick { [weak self] in self?.runMenuRow(row, kind: kind, id: id) }
            let item = NSMenuItem(title: row.item.title.resolved(), action: #selector(MenuClick.click), keyEquivalent: "")
            item.target = click
            item.representedObject = click // the item keeps its target alive
            item.image = NSImage.menuSymbol(row.item.symbol ?? "puzzlepiece.extension")
            item.identifier = NSUserInterfaceItemIdentifier("app-menu:\(row.app)#\(row.item.id)")
            return item
        }
    }

    private func runMenuRow(_ row: MenuRow, kind: String, id: String) {
        let args = row.item.arguments(kind: kind, id: id)
        // task-owner: one menu click's apps-run; nothing waits on it
        Task { [weak self] in
            do throws(AppsClientError) {
                _ = try await self?.run(app: row.app, op: row.item.op, args: args, origin: .user)
            } catch {
                self?.appendLog(row.app, level: "error", message: "\(row.item.op): \(error.description)", date: Date())
            }
        }
    }
}

/// A menu item's click handler (an `NSMenuItem` target is weak; the item holds this).
@MainActor
private final class MenuClick: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func click() { action() }
}
