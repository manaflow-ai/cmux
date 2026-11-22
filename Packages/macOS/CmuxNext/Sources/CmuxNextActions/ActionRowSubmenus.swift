public import AppKit

/// Submenus a menu row of an action opens, built when the menu opens by the action's owner: Screen Sharing ▸
/// lists the machines to view (Leo, 2026-11-18: "you should be able to click the chevron next to teh + of new
/// tab and just go there"). A provider gets the row's target and machine; nil keeps the row a plain one, which
/// runs the action. The row keeps its run (``ActionRegistry/menuRun(of:)``), so a submenu adds, never replaces.
/// One per registry (``ActionRegistry/rowSubmenus``); it lives in its own file, as ActionRegistry.swift is at its size ceiling.
@MainActor
public final class ActionRowSubmenus {
    public typealias Provider = @MainActor (_ target: ActionTargetRef?, _ machineID: String?) -> NSMenu?

    private var providers: [ActionID: Provider] = [:]

    public init() {}

    /// The submenu `id`'s rows open; nil removes it.
    public subscript(id: ActionID) -> Provider? {
        get { providers[id] }
        set { providers[id] = newValue }
    }

    /// Gives `item`, `id`'s row, its owner's submenu when there is one (its title drops the ellipsis).
    func attach(to item: NSMenuItem, id: ActionID, target: ActionTargetRef?, machineID: String?) {
        guard let submenu = providers[id]?(target, machineID) else { return }
        if item.title.hasSuffix("…") { item.title = String(item.title.dropLast()) }
        item.submenu = submenu
    }
}
