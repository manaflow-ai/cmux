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
    /// Opens the shortcut recorder for an action (the Actions menu's Edit
    /// Keyboard Shortcut…); nil hides that command.
    public var editShortcut: (@MainActor (ActionID) -> Void)?
    /// Rows this provider built (a `PaletteItem` made for an action), for the reopen tests.
    private(set) var builtRows = 0
    /// The rows kept across opens: the palette's own (`PaletteController.makeRegistryProvider`), else this provider's.
    var rows = RegistryPaletteRows()

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

    /// The command rows, listed in the palette's order. Each action's shown state is read now; a row whose state is
    /// the one `rows` kept is not built again, and when no listed row changed the last arrangement is listed as it
    /// was (`RegistryPaletteRows`).
    public func makeItems() -> [PaletteItem] {
        let pass = ItemsPass(self)
        _ = pass.read { true }
        return pass.finish()
    }

    /// One ``makeItems()`` that can run in pieces: ``read(while:)`` reads catalog actions while its condition
    /// holds, ``finish()`` arranges what was read. The palette's own open reads them all at once; a list no one
    /// sees this frame (the New Tab page's bar, ``PaletteCommandListing``) reads a few per display frame, so the
    /// main thread never holds every catalog action's state read in one task (PACING TRIAGE #32910: 7-10 ms).
    final class ItemsPass {
        private let provider: RegistryPaletteProvider
        private let kept: RegistryPaletteRows
        /// The catalog as the pass started; each action's state is read when its turn comes.
        private let entries: [ActionEntry]
        private var next = 0
        private var items: [PaletteItem] = []
        private var tiers: [PaletteTier] = []
        private var listed: [RegistryPaletteRows.Listed] = []
        private var eligible = Set<ActionID>()
        // Localized once per pass, not once per action (hundreds of rows).
        private let unbound = PaletteStrings.unbound
        private var labels: RowLabels?
        private var sections: [ActionCategory: PaletteSection] = [:]

        init(_ provider: RegistryPaletteProvider) {
            self.provider = provider
            kept = provider.rows
            kept.context.update(from: provider)
            entries = provider.registry.entries
        }

        // Released with a listing, which a task can release off the main actor.
        nonisolated deinit {}

        /// Reads the next actions while `more()` holds (it is asked before each one). Returns whether every action is read.
        func read(while more: () -> Bool) -> Bool {
            while next < entries.count, more() {
                readEntry(entries[next])
                next += 1
            }
            return next == entries.count
        }

        private func readEntry(_ entry: ActionEntry) {
            let registry = provider.registry
            let descriptor = entry.descriptor
            let actionID = descriptor.id
            guard descriptor.isPaletteVisible, !provider.hiddenIDs.contains(actionID), registry.isAvailable(actionID) else { return }
            // An override is decided when its row runs (`PaletteEffect.deferred`), never on open:
            // Rename Tab and Rename Workspace read every tab and workspace, an action page builds
            // its page. Declining there (nothing to rename) falls back to the action itself.
            let overridden = provider.effectOverrides[actionID] != nil
            guard entry.isBound || overridden || provider.includeUnbound else { return }
            let face = provider.face(of: entry, overridden: overridden, unbound: unbound)
            if !descriptor.isDebugOnly && (entry.isBound || overridden) { eligible.insert(actionID) }
            listed.append(RegistryPaletteRows.Listed(id: actionID, face: face))
            tiers.append(descriptor.paletteTier)
            if let row = kept.rows[actionID], row.face == face {
                items.append(row.item)
                return
            }
            if labels == nil { labels = RowLabels() }
            let section = sections[descriptor.category] ?? RegistryPaletteProvider.section(for: descriptor.category)
            sections[descriptor.category] = section
            let item = provider.makeRow(descriptor, face: face, section: section, labels: labels ?? RowLabels(), context: kept.context)
            kept.rows[actionID] = (face, item)
            provider.builtRows += 1
            items.append(item)
        }

        /// The rows read, in the palette's order (the last arrangement when the same rows list with the same faces).
        func finish() -> [PaletteItem] {
            let curates = provider.curatesEmptyRoot
            if let last = kept.arranged[curates], last.listed == listed { return last.items }
            let arranged = RegistryPaletteProvider.arranged(items, tierList: tiers)
            let result = curates ? provider.curatedRootItems(arranged, eligible: eligible) : arranged
            kept.arranged[curates] = (listed, result)
            return result
        }
    }

    /// What `entry`'s row shows now: its title, why it cannot run, its shortcut.
    private func face(of entry: ActionEntry, overridden: Bool, unbound: String) -> RegistryPaletteRows.Face {
        let descriptor = entry.descriptor
        let action = registry.action(for: descriptor.id)
        // A row whose run would refuse for the focused object (a chat control that chat lacks) says so here.
        let paletteReason = overridden ? nil : action?.paletteUnavailableReason?()
        let runs = overridden || (registry.canPerform(descriptor.id) && paletteReason == nil)
        // A row a person can run past its reason (Sign In, then the action: ``ActionRecovery``) stays enabled.
        let recovery = runs || paletteReason != nil ? nil : registry.personRecovery(for: descriptor.id)
        let isEnabled = runs || recovery != nil
        // An on/off command's state, read now, every open (Lawrence 2026-11-03: "we don't know the current state").
        let isOn = action?.paletteState?()
        let toggleStyle = PaletteTunables.toggleStyle.value
        // A toggle that opts in (`ActionTargetTitles.setPaletteTitle`) reads as the change it makes.
        var title = action?.paletteTitle?() ?? descriptor.title
        if toggleStyle.suffixesTitle, let isOn {
            title = PaletteStrings.titleWithState(title, isOn ? PaletteStrings.on : PaletteStrings.off)
        }
        return RegistryPaletteRows.Face(
            title: title,
            // A disabled row says why (Chromium without a CEF runtime).
            subtitle: recovery?.note ?? (isEnabled ? nil : registry.unavailableReason(for: descriptor.id) ?? paletteReason),
            accessory: entry.isBound || overridden ? nil : unbound,
            // The icon becomes a check while on only in that style; the others draw a trailing badge.
            symbol: toggleStyle.replacesIcon && isOn == true ? "checkmark.circle.fill" : descriptor.symbol,
            isOn: isOn,
            keycaps: registry.shortcutKeycaps(for: descriptor.id),
            keywords: descriptor.keywords,
            isEnabled: isEnabled,
            isBound: entry.isBound,
            overridden: overridden,
            editsShortcut: editShortcut != nil
        )
    }

    /// The localized command titles a built row uses, read once per open that builds any row.
    private struct RowLabels {
        let copyActionID = PaletteStrings.copyActionID
        let open = PaletteStrings.open
        let runCommand = PaletteStrings.runCommand
        let editShortcut = PaletteStrings.editShortcut
    }

    /// `descriptor`'s row showing `face`. Its commands read the palette's state when they run (`context`), so the row
    /// can be kept for later opens.
    private func makeRow(_ descriptor: ActionDescriptor, face: RegistryPaletteRows.Face, section: PaletteSection, labels: RowLabels,
                         context: RegistryPaletteRows.RunContext) -> PaletteItem {
        let actionID = descriptor.id
        let fallback = Self.defaultEffect(for: descriptor, registry: registry, context: context)
        let effect = face.overridden ? PaletteEffect.deferred { context.effectOverrides[actionID]?() ?? fallback } : fallback
        var item = PaletteItem(
            id: "action:\(actionID.rawValue)",
            title: face.title,
            subtitle: face.subtitle,
            accessory: face.accessory,
            symbol: face.symbol,
            keycaps: face.keycaps,
            section: section,
            keywords: face.keywords,
            isEnabled: face.isEnabled,
            primary: PaletteCommand(
                id: "run",
                title: descriptor.arguments.contains(where: \.isRequired) ? labels.open : labels.runCommand,
                symbol: "return",
                effect: effect
            ),
            secondary: (face.editsShortcut ? [
                PaletteCommand(id: "editShortcut", title: labels.editShortcut, symbol: "keyboard",
                               effect: .performKeepingOpen { context.editShortcut?(actionID) }),
            ] : []) + [
                PaletteCommand(
                    id: "copyID",
                    title: labels.copyActionID,
                    symbol: "doc.on.doc",
                    effect: .perform { PaletteClipboard.copy(actionID.rawValue) }
                ),
            ],
            frecencyKey: "action:\(actionID.rawValue)",
            actionID: actionID
        )
        item.toggleState = face.isOn
        item.actionRefs = [PaletteActionRef(actionID, isDestructive: descriptor.isDestructive)]
        item.ball = PaletteGroupColor.ball(forAction: actionID)
        item.suggestedRank = descriptor.paletteSuggestionRank
        item.keywords += ActionDescriptor.paletteAliases[actionID] ?? []
        item.rankBias = Self.rankBias(for: descriptor.paletteTier)
        return item
    }

    /// Decided when the row runs (`PaletteEffect.deferred`): an action
    /// with arguments builds its argument page, target list included, only
    /// then, never for every row on open, with the targets of the open it runs from.
    private static func defaultEffect(for descriptor: ActionDescriptor, registry: ActionRegistry,
                                      context: RegistryPaletteRows.RunContext) -> PaletteEffect {
        let id = descriptor.id
        guard descriptor.arguments.contains(where: \.isRequired) else {
            return .perform { registry.perform(id, invocation: ActionInvocation()) }
        }
        return .deferred {
            PaletteArgumentFlow(registry: registry, descriptor: descriptor, targets: context.targets, captured: context.capturedTargets,
                                preview: context.argumentPreview, swatches: context.argumentSwatches)
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
