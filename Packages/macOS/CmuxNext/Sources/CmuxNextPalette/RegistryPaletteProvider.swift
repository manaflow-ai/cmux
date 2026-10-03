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
    /// Lists objects for target arguments (workspace, tab group, ...).
    public var targets: (any PaletteTargetSource)?
    /// Objects captured when the palette opened; argument-taking actions
    /// target them (`PaletteArgumentFlow`).
    public var capturedTargets: [ActionTargetRef] = []
    /// Live preview for enumeration argument pages (`PaletteSources.argumentPreview`).
    public var argumentPreview: PaletteArgumentPreview?
    /// Palette-internal actions that should not list themselves.
    public var hiddenIDs: Set<ActionID> = ["commandPalette"]
    /// Opens the shortcut recorder for an action (the Actions menu's Edit
    /// Keyboard Shortcut…); nil hides that command.
    public var editShortcut: (@MainActor (ActionID) -> Void)?

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
        // Localized once per open, not once per action (hundreds of rows).
        let unbound = PaletteStrings.unbound
        let copyActionID = PaletteStrings.copyActionID
        let open = PaletteStrings.open
        let runCommand = PaletteStrings.runCommand
        let editTitle = PaletteStrings.editShortcut
        let editShortcut = editShortcut
        var sections: [ActionCategory: PaletteSection] = [:]
        func section(_ category: ActionCategory) -> PaletteSection {
            if let cached = sections[category] { return cached }
            let made = Self.section(for: category)
            sections[category] = made
            return made
        }
        for entry in registry.entries {
            let descriptor = entry.descriptor
            guard descriptor.isPaletteVisible, !hiddenIDs.contains(descriptor.id), registry.isAvailable(descriptor.id) else { continue }
            let override = effectOverrides[descriptor.id]?()
            guard entry.isBound || override != nil || includeUnbound else { continue }
            let isEnabled = override != nil || registry.canPerform(descriptor.id)
            let effect = override ?? defaultEffect(for: descriptor)
            let actionID = descriptor.id
            items.append(PaletteItem(
                id: "action:\(actionID.rawValue)",
                title: descriptor.title,
                // A disabled row says why (Chromium without a CEF runtime).
                subtitle: isEnabled ? nil : registry.unavailableReason(for: actionID),
                accessory: entry.isBound || override != nil ? nil : unbound,
                symbol: descriptor.symbol,
                keycaps: registry.shortcutKeycaps(for: actionID),
                section: section(descriptor.category),
                keywords: descriptor.keywords + [actionID.rawValue],
                isEnabled: isEnabled,
                primary: PaletteCommand(
                    id: "run",
                    title: descriptor.arguments.contains(where: \.isRequired) ? open : runCommand,
                    symbol: "return",
                    effect: effect
                ),
                secondary: (editShortcut.map { edit in
                    [PaletteCommand(id: "editShortcut", title: editTitle, symbol: "keyboard", effect: .performKeepingOpen { edit(actionID) })]
                } ?? []) + [
                    PaletteCommand(
                        id: "copyID",
                        title: copyActionID,
                        symbol: "doc.on.doc",
                        effect: .perform { PaletteClipboard.copy(actionID.rawValue) }
                    ),
                ],
                frecencyKey: "action:\(actionID.rawValue)",
                actionID: actionID
            ))
        }
        return items
    }

    /// Decided when the row runs (`PaletteEffect.deferred`): an action
    /// with arguments builds its argument page, target list included, only
    /// then, never for every row on open.
    private func defaultEffect(for descriptor: ActionDescriptor) -> PaletteEffect {
        let registry = registry
        let id = descriptor.id
        guard descriptor.arguments.contains(where: \.isRequired) else {
            return .perform { registry.perform(id, invocation: ActionInvocation()) }
        }
        return .deferred { [targets, capturedTargets, argumentPreview] in
            PaletteArgumentFlow(registry: registry, descriptor: descriptor, targets: targets, captured: capturedTargets,
                                preview: argumentPreview)
                .effect(collected: ActionInvocation())
        }
    }

    static func primaryTitle(for descriptor: ActionDescriptor) -> String {
        descriptor.arguments.contains(where: \.isRequired) ? PaletteStrings.open : PaletteStrings.runCommand
    }

    /// The section for a catalog category.
    public static func section(for category: ActionCategory) -> PaletteSection {
        PaletteSection(id: category.paletteSectionID, title: category.title, order: category.paletteSectionOrder)
    }
}

enum PaletteClipboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
