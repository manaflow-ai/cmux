import AppKit
public import CmuxNextActions

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

enum PaletteClipboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
