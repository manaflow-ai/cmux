import Foundation

/// Functional domain of an action. Matches the sections of the action catalog
/// in plans/cmux-next/inventory.md section 1.
public nonisolated enum ActionCategory: String, CaseIterable, Sendable, Hashable {
    case window
    case workspace
    case pane
    case screen
    case tab
    case terminal
    case browser
    case sidebar
    case notifications
    case agents
    case cloud
    /// SSH machines (Connect to Machine…).
    case remote
    case settings
    /// Actions registered at runtime without a catalog descriptor.
    case other

    /// Localized section title, from the Rust catalog (cmux-action-catalog `CATEGORIES`).
    public var title: String { RustActionCatalog.shared.categories[self]?.title ?? rawValue }

    /// The localization key of ``title`` (in ``titleTable``), for clients
    /// that read the exported catalog (`action-surfaces.json`).
    public var titleKey: String { RustActionCatalog.shared.categories[self]?.titleKey ?? "category.\(rawValue)" }

    /// The string table ``title`` lives in.
    public var titleTable: String { RustActionCatalog.shared.categories[self]?.titleTable ?? "Localizable" }

    /// The command palette section the category's actions list under.
    public var paletteSectionID: String { "category.\(rawValue)" }

    /// The palette section's order (after the palette's own sections).
    public var paletteSectionOrder: Int { 100 + sortOrder }

    /// Display order of category sections.
    public var sortOrder: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }
}

/// Top-level menus of the menu bar. The App builds each from the actions
/// whose `mainMenu` names it, in catalog order.
public nonisolated enum ActionMainMenu: String, CaseIterable, Sendable, Hashable {
    case app
    case file
    case edit
    case view
    /// Servers the user runs things on (Add Server…, the server panel).
    case server
    case window
    case help
}
