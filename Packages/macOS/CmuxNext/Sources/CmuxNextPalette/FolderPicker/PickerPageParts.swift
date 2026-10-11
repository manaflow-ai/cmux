import Foundation

/// The rows a listing page last built, by id, for its tree keys.
final class PickerPageRows {
    var byID: [String: FolderPickerRow] = [:]
    /// Location rows (`loc:...`) to their folders.
    var locations: [String: URL] = [:]
}

/// The explainer's rows. It counts as shown when the palette shows it
/// (asks for its rows), not when it is built: a palette builds an action's
/// page on every open.
final class PickerExplainerProvider: PaletteProvider {
    let id = "picker.explainer"
    private let rows: [PaletteItem]
    private let memory: (any PickerExplainerMemory)?

    init(items: [PaletteItem], memory: (any PickerExplainerMemory)?) {
        self.rows = items
        self.memory = memory
    }

    // A palette reset (Cmd-Shift-P reopen) can release this inside an
    // action's task-local scope or from a search task; teardown must not
    // need a main-actor hop (RegistryPaletteProvider, #17590).
    nonisolated deinit {}

    var immediateItems: [PaletteItem]? {
        memory?.hasShownExplainer = true
        return rows
    }

    func items() async -> [PaletteItem] { immediateItems ?? [] }
}

/// What a path page read of its folder, and its completion rows by id.
final class PickerPathListing {
    var listing: FolderListing?
    var byID: [String: FolderEntry] = [:]

    func entry(_ id: String) -> FolderEntry? { byID[id] }
}
