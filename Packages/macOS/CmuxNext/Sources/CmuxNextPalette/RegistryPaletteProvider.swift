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
    /// Only the root curates its empty query; the Commands scope retains the full list.
    var curatesEmptyRoot = false
    public var effectOverrides: [ActionID: @MainActor () -> PaletteEffect?] = [:]
    /// Lists objects for target arguments (workspace, tab group, ...).
    public var targets: (any PaletteTargetSource)?
    /// Objects captured when the palette opened; argument-taking actions
    /// target them (`PaletteArgumentFlow`).
    public var capturedTargets: [ActionTargetRef] = []
    /// Live preview for enumeration argument pages (`PaletteSources.argumentPreview`).
    public var argumentPreview: PaletteArgumentPreview?
    /// Swatch strips for suggested argument values (`PaletteSources.argumentSwatches`).
    public var argumentSwatches: PaletteArgumentSwatches?
    /// Palette-internal actions that should not list themselves.
    public var hiddenIDs: Set<ActionID> = ["commandPalette"]
    /// False for a catalog (``PaletteController/commandCatalog()``): every palette-visible row is listed with its
    /// catalog title and symbol, and no row's availability, title or state closure runs, so the list depends only
    /// on the registry's bindings. A shown row asks for its state (``states(of:)``).
    public var decidesRows = true
    /// Opens the shortcut recorder for an action (the Actions menu's Edit
    /// Keyboard Shortcut…); nil hides that command.
    public var editShortcut: (@MainActor (ActionID) -> Void)?

    public init(registry: ActionRegistry, includeUnbound: Bool = RegistryPaletteProvider.defaultIncludeUnbound) {
        self.registry = registry
        self.includeUnbound = includeUnbound
    }

    // Palette searches can retain a page until a task finishes on a generic
    // executor. The provider only stores closures and registry data, so its
    // teardown must not require a main-actor hop when that task releases it.
    nonisolated deinit {}

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
        var tiers: [String: PaletteTier] = [:]
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
            let override = effectOverrides[descriptor.id]
            guard let row = decidesRows ? decide(entry) : listed(entry) else { continue }
            let isEnabled = row.isEnabled
            let fallback = defaultEffect(for: descriptor)
            let effect = override.map { decide in PaletteEffect.deferred { decide() ?? fallback } } ?? fallback
            let actionID = descriptor.id
            var item = PaletteItem(
                id: "action:\(actionID.rawValue)",
                title: row.title,
                // A disabled row says why (Chromium without a CEF runtime).
                subtitle: isEnabled ? nil : registry.unavailableReason(for: actionID) ?? row.reason,
                accessory: entry.isBound || override != nil ? nil : unbound,
                // A toggle that opts in (`ActionTargetTitles.setPaletteState`) shows a check while it is on.
                symbol: decidesRows && registry.action(for: actionID)?.paletteState?() == true ? "checkmark.circle.fill" : descriptor.symbol,
                keycaps: registry.shortcutKeycaps(for: actionID),
                section: section(descriptor.category),
                keywords: descriptor.keywords,
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
            )
            item.actionRefs = [PaletteActionRef(actionID, isDestructive: descriptor.isDestructive)]
            item.ball = PaletteGroupColor.ball(forAction: actionID)
            item.suggestedRank = descriptor.paletteSuggestionRank
            item.keywords += ActionDescriptor.paletteAliases[actionID] ?? []
            item.rankBias = Self.rankBias(for: descriptor.paletteTier)
            tiers[item.id] = descriptor.paletteTier
            items.append(item)
        }
        let arranged = Self.arranged(items, tiers: tiers)
        return curatesEmptyRoot ? curatedRootItems(arranged) : arranged
    }

    /// A row as the palette decides it now: listed, enabled and titled for the focused object.
    public struct RowState: Equatable, Sendable {
        /// Whether the row runs now (the palette shows a disabled row dimmed).
        public var isEnabled: Bool
        /// The row's title now: a toggle that opts in (`ActionTargetTitles.setPaletteTitle`) reads as the change it makes.
        public var title: String
        /// Why the row cannot run for the focused object, when the action says so.
        var reason: String?
    }

    /// The rows of `ids` decided now; an id the palette does not list here (not palette-visible, hidden, not
    /// available in this context, or unbound) is left out. The palette's own rows are decided by the same code.
    public func states(of ids: Set<ActionID>) -> [ActionID: RowState] {
        var out: [ActionID: RowState] = [:]
        for entry in registry.entries where ids.contains(entry.descriptor.id) {
            if let row = decide(entry) { out[entry.descriptor.id] = row }
        }
        return out
    }

    /// Whether `entry` is a row at all, independent of state (``decidesRows`` false).
    private func listed(_ entry: ActionEntry) -> RowState? {
        let descriptor = entry.descriptor
        guard descriptor.isPaletteVisible, !hiddenIDs.contains(descriptor.id),
              entry.isBound || effectOverrides[descriptor.id] != nil || includeUnbound else { return nil }
        return RowState(isEnabled: true, title: descriptor.title)
    }

    /// The row of `entry` decided now: listed in this context, enabled, and its current title.
    private func decide(_ entry: ActionEntry) -> RowState? {
        let descriptor = entry.descriptor
        guard listed(entry) != nil, registry.isAvailable(descriptor.id) else { return nil }
        // An override is decided when its row runs (`PaletteEffect.deferred`), never on open:
        // Rename Tab and Rename Workspace read every tab and workspace, an action page builds
        // its page. Declining there (nothing to rename) falls back to the action itself.
        let override = effectOverrides[descriptor.id]
        // A row whose run would refuse for the focused object (a chat control that chat lacks) says so here.
        let reason = override == nil ? registry.action(for: descriptor.id)?.paletteUnavailableReason?() : nil
        let isEnabled = override != nil || (registry.canPerform(descriptor.id) && reason == nil)
        return RowState(isEnabled: isEnabled, title: registry.action(for: descriptor.id)?.paletteTitle?() ?? descriptor.title,
                        reason: reason)
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
        return .deferred { [targets, capturedTargets, argumentPreview, argumentSwatches] in
            PaletteArgumentFlow(registry: registry, descriptor: descriptor, targets: targets, captured: capturedTargets,
                                preview: argumentPreview, swatches: argumentSwatches)
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
