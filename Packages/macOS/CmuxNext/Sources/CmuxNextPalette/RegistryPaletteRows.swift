import CmuxNextActions

/// The command rows kept from one palette open to the next (SHORTCUT PERF 2: every Shift-Cmd-P open spent 14 ms of
/// its key's turn building a row per catalog action, sorting them and folding the families). As Chrome's omnibox
/// keeps its providers' matches and updates them in place, an open reads each action's shown state (its `Face`) and
/// builds again, by action id, only the rows whose face changed; when no row and no listed action changed, it lists
/// the last open's arrangement as it was. The palette keeps one for its whole life
/// (`PaletteController.makeRegistryProvider`); a provider made without one builds every row once.
final class RegistryPaletteRows {
    /// What a row shows that can change between opens. The rest of a row comes from its catalog descriptor, which
    /// does not change at run time; an action registered with no descriptor shows its own title and keywords, kept
    /// here too.
    struct Face: Equatable {
        var title: String
        var subtitle: String?
        var accessory: String?
        var symbol: String?
        /// Whether an on/off command is on now (`ActionTargetTitles.setPaletteState`); nil for any other row.
        var isOn: Bool?
        var keycaps: [String]?
        var keywords: [String]
        var isEnabled: Bool
        var isBound: Bool
        var overridden: Bool
        var editsShortcut: Bool
    }

    /// One listed row: the open's arrangement is kept while the same rows list with the same faces.
    struct Listed: Equatable {
        var id: ActionID
        var face: Face
    }

    /// What a kept row's commands read when they run: set by each open from its provider, so a row built at an
    /// earlier open runs with this open's captured targets, overrides and shortcut editor.
    final class RunContext {
        var targets: (any PaletteTargetSource)?
        var capturedTargets: [ActionTargetRef] = []
        var argumentPreview: PaletteArgumentPreview?
        var argumentSwatches: PaletteArgumentSwatches?
        var effectOverrides: [ActionID: @MainActor () -> PaletteEffect?] = [:]
        var editShortcut: (@MainActor (ActionID) -> Void)?

        /// The state `provider` runs its rows with, for the open that reads its rows now.
        func update(from provider: RegistryPaletteProvider) {
            targets = provider.targets
            capturedTargets = provider.capturedTargets
            argumentPreview = provider.argumentPreview
            argumentSwatches = provider.argumentSwatches
            effectOverrides = provider.effectOverrides
            editShortcut = provider.editShortcut
        }
    }

    let context = RunContext()
    /// Each action's row and the face it was built for.
    var rows: [ActionID: (face: Face, item: PaletteItem)] = [:]
    /// The last arrangement, by whether it curated the empty root: the rows it listed and its result.
    var arranged: [Bool: (listed: [Listed], items: [PaletteItem])] = [:]

    init() {}

    // Released with a palette page, which a search task can release off the main actor (#17590).
    nonisolated deinit {}
}
