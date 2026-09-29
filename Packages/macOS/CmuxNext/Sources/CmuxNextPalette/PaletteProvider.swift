import AppKit
public import CmuxNextActions

/// Supplies palette items. The palette asks every provider of a page when
/// the page opens (and after a keep-open command), then searches the items
/// locally, so providers return their whole candidate set and never see
/// keystrokes.
public protocol PaletteProvider: AnyObject {
    var id: String { get }
    /// Whether items appear before the user types. Dynamic sources on the
    /// root page (workspaces, tabs) set this false to keep the command list
    /// short; nested pages set it true.
    var showsItemsForEmptyQuery: Bool { get }
    /// Items available synchronously, used on open so the first frame is
    /// never empty. Nil means "call `items()`".
    var immediateItems: [PaletteItem]? { get }
    func items() async -> [PaletteItem]
}

extension PaletteProvider {
    public var showsItemsForEmptyQuery: Bool { true }
    public var immediateItems: [PaletteItem]? { nil }
}

/// Every catalog action available in the current context.
///
/// Bound actions run through the registry. Actions whose descriptor takes
/// text get inline text entry. `effectOverrides` lets the palette serve an
/// action itself (a nested list for Go to Workspace), which also makes it
/// usable before the App binds it. Unbound actions appear disabled in debug
/// builds and are hidden in release builds.
public final class RegistryPaletteProvider: PaletteProvider {
    public let id = "registry"
    public let registry: ActionRegistry
    public var includeUnbound: Bool
    public var effectOverrides: [ActionID: @MainActor () -> PaletteEffect?] = [:]
    /// Palette-internal actions that should not list themselves.
    public var hiddenIDs: Set<ActionID> = ["commandPalette", "commandPaletteNext", "commandPalettePrevious"]

    public init(registry: ActionRegistry, includeUnbound: Bool = RegistryPaletteProvider.defaultIncludeUnbound) {
        self.registry = registry
        self.includeUnbound = includeUnbound
    }

    public static var defaultIncludeUnbound: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    public var immediateItems: [PaletteItem]? { makeItems() }

    public func items() async -> [PaletteItem] { makeItems() }

    public func makeItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        for entry in registry.entries {
            let descriptor = entry.descriptor
            guard !hiddenIDs.contains(descriptor.id), registry.isAvailable(descriptor.id) else { continue }
            let override = effectOverrides[descriptor.id]?()
            guard entry.isBound || override != nil || includeUnbound else { continue }
            let isEnabled = override != nil || registry.canPerform(descriptor.id)
            let effect = override ?? defaultEffect(for: descriptor)
            let actionID = descriptor.id
            items.append(PaletteItem(
                id: "action:\(actionID.rawValue)",
                title: descriptor.title,
                accessory: entry.isBound || override != nil ? nil : PaletteStrings.unbound,
                symbol: descriptor.symbol,
                keycaps: registry.shortcutKeycaps(for: actionID),
                section: Self.section(for: descriptor.category),
                keywords: descriptor.keywords + [actionID.rawValue],
                isEnabled: isEnabled,
                primary: PaletteCommand(
                    id: "run",
                    title: Self.primaryTitle(for: descriptor.input),
                    symbol: "return",
                    effect: effect
                ),
                secondary: [
                    PaletteCommand(
                        id: "copyID",
                        title: PaletteStrings.copyActionID,
                        symbol: "doc.on.doc",
                        effect: .perform { PaletteClipboard.copy(actionID.rawValue) }
                    ),
                ],
                frecencyKey: "action:\(actionID.rawValue)"
            ))
        }
        return items
    }

    private func defaultEffect(for descriptor: ActionDescriptor) -> PaletteEffect {
        let registry = registry
        let id = descriptor.id
        if descriptor.input == .text, registry.action(for: id)?.argumentHandler != nil {
            return .textInput(PaletteTextInputSpec(
                id: "input:\(id.rawValue)",
                title: descriptor.title,
                placeholder: descriptor.title,
                symbol: descriptor.symbol,
                submitTitle: { text in PaletteStrings.submitText(title: descriptor.title, text: text) },
                submit: { text in registry.perform(id, argument: text) }
            ))
        }
        return .perform { registry.perform(id) }
    }

    static func primaryTitle(for input: ActionInput) -> String {
        switch input {
        case .none: PaletteStrings.runCommand
        case .text, .list: PaletteStrings.open
        }
    }

    /// The section for a catalog category.
    public static func section(for category: ActionCategory) -> PaletteSection {
        PaletteSection(id: "category.\(category.rawValue)", title: category.title, order: 100 + category.sortOrder)
    }
}

/// "Search Keyboard Shortcuts": every action with a shortcut, searchable by
/// title or by shortcut words ("cmd shift p", "⌘D").
public final class KeyboardShortcutsPaletteProvider: PaletteProvider {
    public let id = "shortcuts"
    public let registry: ActionRegistry

    public init(registry: ActionRegistry) {
        self.registry = registry
    }

    public var immediateItems: [PaletteItem]? { makeItems() }
    public func items() async -> [PaletteItem] { makeItems() }

    public func makeItems() -> [PaletteItem] {
        registry.entries.compactMap { entry -> PaletteItem? in
            let id = entry.descriptor.id
            guard let keycaps = registry.shortcutKeycaps(for: id) else { return nil }
            var keywords = entry.descriptor.keywords + [id.rawValue]
            if let shortcut = registry.effectiveShortcut(for: id) { keywords += shortcut.searchTokens }
            keywords.append(keycaps.joined())
            let registry = registry
            return PaletteItem(
                id: "shortcut:\(id.rawValue)",
                title: entry.descriptor.title,
                subtitle: entry.descriptor.category.title,
                symbol: entry.descriptor.symbol,
                keycaps: keycaps,
                section: RegistryPaletteProvider.section(for: entry.descriptor.category),
                keywords: keywords,
                isEnabled: registry.canPerform(id),
                primary: PaletteCommand(id: "run", title: PaletteStrings.runCommand, symbol: "return", effect: .perform { registry.perform(id) }),
                secondary: [
                    PaletteCommand(id: "copyID", title: PaletteStrings.copyActionID, symbol: "doc.on.doc", effect: .perform { PaletteClipboard.copy(id.rawValue) }),
                    PaletteCommand(id: "copyShortcut", title: PaletteStrings.copyShortcut, symbol: "keyboard", effect: .perform { PaletteClipboard.copy(keycaps.joined()) }),
                ],
                frecencyKey: "action:\(id.rawValue)"
            )
        }
    }
}

/// A provider over a fixed item list (extensions, tests, custom actions).
public final class StaticPaletteProvider: PaletteProvider {
    public let id: String
    public var itemsList: [PaletteItem]
    public let showsItemsForEmptyQuery: Bool

    public init(id: String, items: [PaletteItem], showsItemsForEmptyQuery: Bool = true) {
        self.id = id
        self.itemsList = items
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
    }

    public var immediateItems: [PaletteItem]? { itemsList }
    public func items() async -> [PaletteItem] { itemsList }
}

/// A provider backed by an async closure (daemon queries, file system scans).
public final class AsyncPaletteProvider: PaletteProvider {
    public let id: String
    public let showsItemsForEmptyQuery: Bool
    private let load: @MainActor () async -> [PaletteItem]

    public init(id: String, showsItemsForEmptyQuery: Bool = true, load: @escaping @MainActor () async -> [PaletteItem]) {
        self.id = id
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
        self.load = load
    }

    public func items() async -> [PaletteItem] { await load() }
}

enum PaletteClipboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
