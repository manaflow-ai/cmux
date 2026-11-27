import AppKit
public import CmuxNextActions

/// Every catalog action that can run in the current context. A bound row that cannot run here (no
/// target for it, a chat that lacks the control, an action switched off) is not listed and no
/// search finds it; a CLI or MCP run of the action still gets the reason (Leo 2026-11-17: "just...
/// stop showijg the toggle on gui").
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
    /// What the curated root's empty query can show besides its intents, read on each open: the user's pinned
    /// actions and the rows the usage history can list as Recent (`PaletteController.commandsPage`). With it, the
    /// open's first frame reads only those actions and the root's (``firstFrameItems``); without it, every catalog
    /// action before the first frame.
    var firstFrameRows: (@MainActor () -> FirstFrameRows)?
    /// The reads of this open's first frame, which the full read after it takes as read: the rows it showed.
    private var firstFrameReads: [ActionID: ItemsPass.Read]?
    public var effectOverrides: [ActionID: @MainActor () -> PaletteEffect?] = [:]
    /// Lists objects for target arguments (workspace, tab group, ...).
    public var targets: (any PaletteTargetSource)?
    /// Makes a target from a typed name on an argument page (`PaletteSources.targetCreators`).
    public var targetCreators: [ActionTargetKind: PaletteTargetCreator] = [:]
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

    /// The curated root's first frame (Cmd-Shift-P): only the catalog actions its empty query can show, read as
    /// ``makeItems()`` reads them, of the hundreds a typed query searches (``ItemsPass/readFirstFrame(_:)``). The
    /// model reads ``makeItems()`` after the frame, which takes these reads as read. Nil without ``firstFrameRows``.
    public var firstFrameItems: [PaletteItem]? {
        guard curatesEmptyRoot, let shown = firstFrameRows?() else { return nil }
        var wanted = Self.rootIntentIDs.union(shown.actions)
        for family in ActionDescriptor.paletteFamilies where shown.families.contains(family.id) {
            // A recent family row lists, and runs, when one of its members does: all of them are read.
            wanted.formUnion(family.members)
            if let parent = family.parent { wanted.insert(parent) }
        }
        let pass = ItemsPass(self, recordsReads: true)
        pass.readFirstFrame(wanted)
        firstFrameReads = pass.reads
        return pass.finishFirstFrame()
    }

    /// The command rows, listed in the palette's order. Each action's shown state is read now (an action this open's
    /// first frame read keeps what that read found: the row it showed); a row whose state is the one `rows` kept is
    /// not built again, and when no listed row changed the last arrangement is listed as it was (`RegistryPaletteRows`).
    public func makeItems() -> [PaletteItem] {
        let pass = ItemsPass(self, earlier: firstFrameReads ?? [:])
        firstFrameReads = nil
        _ = pass.read { true }
        return pass.finish()
    }

    /// What the root's empty query can show besides its intents (``firstFrameRows``).
    struct FirstFrameRows {
        /// Pinned actions and actions the usage history knows.
        var actions: Set<ActionID> = []
        /// Families (`ActionDescriptor.paletteFamilies` ids) the usage history knows: their rows can be Recent.
        var families: Set<String> = []

        /// From the usage history's row keys (`action:ID`, `family:ID`, as the rows set them) and the pinned action ids.
        init(keys: Set<String>, pins: [String]) {
            for key in keys {
                if key.hasPrefix("action:") {
                    actions.insert(ActionID(rawValue: String(key.dropFirst("action:".count))))
                } else if key.hasPrefix("family:") {
                    families.insert(String(key.dropFirst("family:".count)))
                }
            }
            actions.formUnion(pins.map { ActionID(rawValue: $0) })
        }
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
        /// Catalog actions whose state this pass read so far.
        var readCount: Int { next }
        private var items: [PaletteItem] = []
        private var tiers: [PaletteTier] = []
        private var listed: [RegistryPaletteRows.Listed] = []
        private var eligible = Set<ActionID>()
        // Localized once per pass, not once per action (hundreds of rows).
        private let unbound = PaletteStrings.unbound
        private var labels: RowLabels?
        private var sections: [ActionCategory: PaletteSection] = [:]
        /// What reading one catalog action found: not listed, or listed with the face it shows and whether the root
        /// may show it (bound or served by the palette, not debug-only).
        enum Read {
            case unlisted
            case listed(RegistryPaletteRows.Face, eligible: Bool)
        }
        /// Reads an earlier pass of this open made (its first frame's), taken as read.
        private let earlier: [ActionID: Read]
        private let recordsReads: Bool
        /// Each action this pass read and what it found (`recordsReads`).
        private(set) var reads: [ActionID: Read] = [:]

        init(_ provider: RegistryPaletteProvider, earlier: [ActionID: Read] = [:], recordsReads: Bool = false) {
            self.provider = provider
            self.earlier = earlier
            self.recordsReads = recordsReads
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

        /// What `entry`'s row is now: whether it lists, its face.
        private func read(_ entry: ActionEntry) -> Read {
            let registry = provider.registry
            let descriptor = entry.descriptor
            let actionID = descriptor.id
            guard descriptor.isPaletteVisible, !provider.hiddenIDs.contains(actionID),
                  registry.isAvailable(actionID, in: provider.paletteContext(for: descriptor)) else { return .unlisted }
            // An override is decided when its row runs (`PaletteEffect.deferred`), never on open:
            // Rename Tab and Rename Workspace read every tab and workspace, an action page builds
            // its page. Declining there (nothing to rename) falls back to the action itself.
            let overridden = provider.effectOverrides[actionID] != nil
            guard entry.isBound || overridden || provider.includeUnbound else { return .unlisted }
            let face = provider.face(of: entry, overridden: overridden, unbound: unbound)
            guard face.isEnabled || !entry.isBound else { return .unlisted }
            return .listed(face, eligible: !descriptor.isDebugOnly && (entry.isBound || overridden))
        }

        /// Reads `entry` (or takes an earlier read of it) and adds its row when it lists. Returns what it found.
        @discardableResult
        private func readEntry(_ entry: ActionEntry) -> Read {
            let descriptor = entry.descriptor
            let actionID = descriptor.id
            let found = earlier[actionID] ?? read(entry)
            if recordsReads { reads[actionID] = found }
            guard case .listed(let face, let isEligible) = found else { return found }
            if isEligible { eligible.insert(actionID) }
            listed.append(RegistryPaletteRows.Listed(id: actionID, face: face))
            tiers.append(descriptor.paletteTier)
            if let row = kept.rows[actionID], row.face == face {
                items.append(row.item)
                return found
            }
            if labels == nil { labels = RowLabels() }
            let section = sections[descriptor.category] ?? RegistryPaletteProvider.section(for: descriptor.category)
            sections[descriptor.category] = section
            let item = provider.makeRow(descriptor, face: face, section: section, labels: labels ?? RowLabels(), context: kept.context)
            kept.rows[actionID] = (face, item)
            provider.builtRows += 1
            items.append(item)
            return found
        }

        /// The curated root's first frame: in catalog order, the actions in `wanted`, and for each root family
        /// (``RegistryPaletteProvider/rootFamilies``) the actions of its sections until one lists for the root and one
        /// lists enabled: what decides whether the family's row shows and runs (`curatedRootItems`). Every other action
        /// is left for the full read.
        func readFirstFrame(_ wanted: Set<ActionID>) {
            let bySection = RegistryPaletteProvider.rootFamiliesBySectionID
            var listsEligible = [Bool](repeating: false, count: RegistryPaletteProvider.rootFamilies.count)
            var anyEnabled = listsEligible
            for entry in entries {
                let families = bySection[entry.descriptor.category.paletteSectionID] ?? []
                let decides = families.contains { !(listsEligible[$0] && anyEnabled[$0]) }
                guard decides || wanted.contains(entry.descriptor.id) else { continue }
                guard case .listed(let face, let isEligible) = readEntry(entry) else { continue }
                for family in families {
                    if isEligible { listsEligible[family] = true }
                    if face.isEnabled { anyEnabled[family] = true }
                }
            }
            next = entries.count
        }

        /// ``readFirstFrame(_:)``'s rows, arranged and curated as ``finish()`` arranges every row; not kept as the
        /// last arrangement, which is the full read's.
        func finishFirstFrame() -> [PaletteItem] {
            let arranged = RegistryPaletteProvider.arranged(items, tierList: tiers)
            return provider.curatedRootItems(arranged, eligible: eligible)
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

    /// What `entry`'s row shows now: its title, whether it runs, its shortcut.
    private func face(of entry: ActionEntry, overridden: Bool, unbound: String) -> RegistryPaletteRows.Face {
        let descriptor = entry.descriptor
        let action = registry.action(for: descriptor.id)
        // A row whose run would refuse for the focused object (a chat control that chat lacks) cannot run here.
        let collectsTarget = descriptor.paletteTarget != nil
        let paletteReason = overridden || collectsTarget ? nil : action?.paletteUnavailableReason?()
        let runs = overridden || (registry.canPerform(descriptor.id, in: paletteContext(for: descriptor)) && paletteReason == nil)
        // A row a person can run past its reason (Sign In, then the action: ``ActionRecovery``) stays enabled.
        let recovery = runs || paletteReason != nil ? nil : registry.personRecovery(for: descriptor.id)
        let isEnabled = runs || recovery != nil
        // An on/off command's state, read now, every open (Lawrence 2026-11-03: "we don't know the current state").
        let isOn = action?.paletteState?()
        // A toggle that opts in (`ActionTargetTitles.setPaletteTitle`) reads as the change it makes.
        // The state shows the one way every row that flips a state shows it (`PaletteToggleStyle.apply`).
        let shown = PaletteTunables.toggleStyle.value.apply(title: action?.paletteTitle?() ?? descriptor.title,
                                                            symbol: descriptor.symbol, isOn: isOn)
        return RegistryPaletteRows.Face(
            title: shown.title,
            // What the row does when its title alone does not say (``ActionDescriptor/hint``); a hint that only
            // says the title again is narration and goes.
            subtitle: recovery?.note ?? (isEnabled ? descriptor.hint.flatMap { $0.restatesTitle(shown.title) ? nil : $0 } : nil),
            accessory: entry.isBound || overridden ? nil : unbound,
            symbol: shown.symbol,
            isOn: isOn,
            flipsInPlace: isOn != nil && Self.flipsInPlace(descriptor, action: action),
            keycaps: registry.shortcutKeycaps(for: descriptor.id),
            // A row named by its setting ("Focus Ring") is still found by the verb people type.
            keywords: isOn == nil ? descriptor.keywords : descriptor.keywords + ["toggle"],
            isEnabled: isEnabled,
            isBound: entry.isBound,
            overridden: overridden,
            editsShortcut: editShortcut != nil
        )
    }

    /// A subject picker can supply the context implied by that target kind.
    /// Feature, sign-in and other availability predicates still run normally.
    private func paletteContext(for descriptor: ActionDescriptor) -> ActionContext {
        registry.context.union(ActionContext.implied(byTargetKind: descriptor.paletteTarget))
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
        let fallback = Self.defaultEffect(for: descriptor, registry: registry, context: context, flipsInPlace: face.flipsInPlace)
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
                title: descriptor.paletteTarget != nil || descriptor.arguments.contains(where: \.palettePrompts) ? labels.open : labels.runCommand,
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
        if face.isOn != nil {
            let registry = registry
            item.readsToggleState = { registry.action(for: actionID)?.paletteState?() ?? false }
            item.toggleBase = (registry.action(for: actionID)?.paletteTitle?() ?? descriptor.title, descriptor.symbol)
        }
        item.actionRefs = [PaletteActionRef(actionID, isDestructive: descriptor.isDestructive)]
        item.ball = PaletteGroupColor.ball(forAction: actionID)
        item.suggestedRank = descriptor.paletteSuggestionRank
        item.aliases = ActionDescriptor.paletteAliases[actionID] ?? []
        item.keywords += item.aliases
        item.rankBias = Self.rankBias(for: descriptor.paletteTier)
        // Read only for the row the preview pane shows (`experiments.palettePreview`).
        let (name, keycaps, category, hint) = (descriptor.title, face.keycaps, descriptor.category, descriptor.hint)
        item.facts = { PaletteFacts.command(name: name, keycaps: keycaps, category: category.title, description: hint) }
        return item
    }

    /// Decided when the row runs (`PaletteEffect.deferred`): an action
    /// with arguments builds its argument page, target list included, only
    /// then, never for every row on open, with the targets of the open it runs from.
    private static func defaultEffect(for descriptor: ActionDescriptor, registry: ActionRegistry,
                                      context: RegistryPaletteRows.RunContext, flipsInPlace: Bool = false) -> PaletteEffect {
        let id = descriptor.id
        guard descriptor.paletteTarget != nil || descriptor.arguments.contains(where: \.palettePrompts) else {
            // A setting's on/off row flips in place: the palette stays open and the row reads its new state.
            if flipsInPlace { return .performKeepingOpen { registry.perform(id, invocation: ActionInvocation()) } }
            return .perform { registry.perform(id, invocation: ActionInvocation()) }
        }
        return .deferred {
            // Sign in before reading the account's inventory. The recovery
            // returns to collection once it has the signed-in machine list.
            if registry.personRecovery(for: id) != nil {
                return .perform { registry.perform(id, invocation: ActionInvocation()) }
            }
            return PaletteArgumentFlow(registry: registry, descriptor: descriptor, targets: context.targets, captured: context.capturedTargets,
                                preview: context.argumentPreview, swatches: context.argumentSwatches,
                                creators: context.targetCreators)
                .effect(collected: ActionInvocation())
        }
    }

    /// Whether `descriptor`'s row flips an on/off setting, which Return or a click flips without closing
    /// the palette (Leo 2026-11-07: "just unify"), as a Settings row does: only an action that says so
    /// (`ActionTargetTitles.setPaletteSettingState`: Focus Ring, Pane Borders, the animation switches).
    /// A preset with a state (Density: Compact) picks a value and closes, and so does an on/off command
    /// on what is in front (Left Sidebar, Copy Mode, Dictation).
    static func flipsInPlace(_ descriptor: ActionDescriptor, action: Action?) -> Bool {
        !descriptor.arguments.contains(where: \.palettePrompts) && action?.paletteStateIsSetting == true
    }

    static func primaryTitle(for descriptor: ActionDescriptor) -> String {
        descriptor.paletteTarget != nil || descriptor.arguments.contains(where: \.palettePrompts) ? PaletteStrings.open : PaletteStrings.runCommand
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
