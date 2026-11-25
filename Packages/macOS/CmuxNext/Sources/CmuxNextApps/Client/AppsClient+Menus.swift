import Foundation

/// `contributes.menus`: the rows apps add to cmux's own right-click menus. A
/// menu reads them from the install mirror each time it opens, so a saved
/// manifest (`apps-changed`, which lists again) shows on the next right-click
/// with no relaunch. Each row is a registry row running `app.menu.run` (the App
/// builds it), so the menu, the CLI and MCP run one path.
extension AppsClient {
    /// One app's row in a menu.
    public struct MenuRow: Sendable, Hashable {
        public var app: String
        public var item: AppMenuItem

        /// The row's identifier in a menu (`app-menu:<app>#<item>`).
        public var identifier: String { "app-menu:\(app)#\(item.id)" }
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

    /// Visible app `app`'s row `item` (any menu), nil when no visible app has it now.
    public func menuRow(app: String, item: String) -> MenuRow? {
        guard isListed, let record = apps.first(where: { $0.id == app && $0.isVisible }),
              let row = record.manifest.menuItems.first(where: { $0.id == item }) else { return nil }
        return MenuRow(app: record.id, item: row)
    }

    /// Runs `row`'s op on the right-clicked `kind` `id` (`args.target`) with `origin`; a refusal goes
    /// to the app's log and is returned.
    public func runMenuRow(_ row: MenuRow, kind: String, id: String, origin: AppOrigin) async -> AppsClientError? {
        do throws(AppsClientError) {
            _ = try await run(app: row.app, op: row.item.op, args: row.item.arguments(kind: kind, id: id), origin: origin)
            return nil
        } catch {
            appendLog(row.app, level: "error", message: "\(row.item.op): \(error.description)", date: Date())
            return error
        }
    }
}
