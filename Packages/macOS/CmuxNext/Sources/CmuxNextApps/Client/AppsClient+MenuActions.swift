public import AppKit
public import CmuxNextActions
import CmuxNextDesign

/// `contributes.menus` rows as registry rows (Lawrence 2026-10-19: a context menu row runs a registered
/// action, never an inline selector): each runs `app.menu.run` with its app, its item id and the
/// right-clicked object, so the menu, the CLI and MCP run one path.
extension AppsClient {
    /// Puts the visible apps' rows into `registry`'s workspace row, tab and terminal menus
    /// (``ActionRegistry/contributedMenuItems``, read at each open, so `apps-changed` shows on the next
    /// right-click) and binds `app.menu.run`, which a row runs. None while an administrator turned apps off.
    public func installMenuRows(in registry: ActionRegistry) {
        registry.contributedMenuItems = { [weak self, weak registry] context, subject in
            guard let self, let registry, !registry.disabledFeatures.contains(.apps),
                  let target = AppMenuItem.Target(menuContext: context.rawValue) else { return [] }
            return menuItems(for: target, in: context, on: subject, registry: registry)
        }
        registry.bindEffect("app.menu.run", effect: { [weak self] invocation in
            self?.menuRunEffect(invocation) ?? .refused(AppsStrings.menuUnknownRow)
        })
    }

    /// `target`'s app rows in the `context` menu on `subject`, built by `registry` (``menuRows(for:)``),
    /// titled and drawn by their apps, identified `app-menu:<app>#<item>`.
    public func menuItems(for target: AppMenuItem.Target, in context: ActionMenuContext, on subject: ActionTargetRef,
                          registry: ActionRegistry) -> [NSMenuItem] {
        menuRows(for: target).compactMap { row in
            let arguments: [String: ActionValue] = ["app": .string(row.app), "item": .string(row.item.id)]
            guard let item = registry.makeContextMenuItem(for: "app.menu.run", in: context, target: subject, arguments: arguments,
                                                          title: row.item.title.resolved()) else { return nil }
            item.image = NSImage.menuSymbol(row.item.symbol ?? "puzzlepiece.extension")
            item.identifier = NSUserInterfaceItemIdentifier(row.identifier)
            return item
        }
    }

    /// `app.menu.run`'s effect: the row `item` of app `app` on the invocation's target, with its origin; a refusal
    /// goes to the app's log (``runMenuRow(_:kind:id:origin:)``).
    public func menuRunEffect(_ invocation: ActionInvocation) -> ActionEffect {
        if let reason = unavailableReason { return .refused(reason.text) }
        let app = invocation["app"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let row = menuRow(app: app, item: invocation["item"]?.stringValue ?? "") else { return .refused(AppsStrings.menuUnknownRow) }
        guard let subject = invocation.target else { return .refused(AppsStrings.menuNoTarget) }
        let origin = AppOrigin(rawValue: invocation.origin.rawValue) ?? .script
        // action-wait-allow: the row's op runs in the app's own process; cmux has no change of its own to show first
        return .waiting(.externalProcess) { [weak self] in
            guard let self else { return nil }
            return await runMenuRow(row, kind: subject.kind.rawValue, id: subject.id, origin: origin).map { ActionWorkFailure($0.description) }
        }
    }
}
