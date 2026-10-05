import AppKit
import CmuxNextPalette
import UniformTypeIdentifiers

/// The cmux picker (R89): cmux's own open and save panel, a palette page
/// that walks one folder level at a time. Every open and save panel in
/// cmux-next goes through it (R96, the dialogs lead: no NSOpenPanel or
/// NSSavePanel). The palette module owns the models (`PickerSession`,
/// `FolderPickerState`, `FolderListing`, `PickerSaveName`); this is the
/// app's door to them.
///
/// ```swift
/// let urls = await services.viewers.picker.open(.init(choose: .files, allowsMultiple: true, types: [.image]))
/// let target = await services.viewers.picker.save(.init(name: "notes.md", types: [markdown, .plainText]))
/// ```
///
/// Both return nil when the user leaves (Escape on an empty query, a click
/// elsewhere, the palette opening another page). Typing filters the folder
/// shown, always (the palette's fuzzy matcher, prefix matches first in
/// Finder order; dot entries only for a query that starts with `.`). A
/// query that starts with `/` or `~/` is a path: it completes one segment
/// at a time (Tab or Right completes, Return goes there). At the start
/// folder an empty query shows Locations: Recent, the workspace's folders,
/// Home, Desktop, Documents, Downloads, iCloud Drive, `picker.pinned`.
/// Up/Down and Ctrl-N/Ctrl-P move; Tab or Right enters a folder; Left,
/// Backspace on an empty query or Cmd-Up goes up; the footer's path
/// segments are clickable; Return chooses; Cmd-Return marks an item when
/// several may be chosen. Save: the query is the name (prefilled, its name
/// part selected); typing `folder/` goes to that folder and keeps the name;
/// Return on an existing name asks before replacing it (a palette page
/// until CmuxDialog lands, `PickerOverwriteConfirming`). The first visit to
/// a protected folder (Desktop, Documents, Downloads, iCloud Drive, a
/// volume) shows one explainer before macOS asks; a refused folder offers
/// its System Settings pane. Listing never looks inside Desktop,
/// Documents, Downloads, Library, Movies, Music or Pictures unless the user
/// opens them.
@MainActor
final class CmuxPicker {
    struct OpenOptions {
        var choose: PickerMode.Choice = .files
        var allowsMultiple = false
        /// The types that may be chosen; empty: any file.
        var types: [UTType] = []
        /// With `types`: the user may switch to All Files.
        var allowsAllFiles = true
        /// Where the picker opens; nil: home.
        var startDirectory: URL?
        /// Shown before the path in the palette's footer.
        var title: String?
        /// The field's placeholder.
        var prompt: String?
        /// The recents listed first (at the start folder).
        var recents: [ViewerRecents.Kind] = []
        /// Type filters cmux names itself (Markdown), on top of `types`.
        var filter: PickerFilter?
    }

    struct SaveOptions {
        /// The name the field starts with (its name part is selected).
        var name = ""
        /// The types it may be saved as, the default first; empty: any.
        var types: [UTType] = []
        var startDirectory: URL?
        var title: String?
        var prompt: String?
        var filter: PickerFilter?
    }

    private weak var services: AppServices?
    private let recents: ViewerRecents
    private let explainer: any PickerExplainerMemory

    init(services: AppServices, recents: ViewerRecents,
         explainer: any PickerExplainerMemory = UserDefaultsPickerExplainerMemory()) {
        self.services = services
        self.recents = recents
        self.explainer = explainer
    }

    /// Chooses files or folders; nil when the user leaves.
    func open(_ options: OpenOptions, over window: NSWindow? = nil) async -> [URL]? {
        await withCheckedContinuation { continuation in
            guard let palette = services?.palette else { return continuation.resume(returning: nil) }
            palette.show(page: openPage(options) { continuation.resume(returning: $0) }, relativeTo: window)
        }
    }

    /// Chooses a new file's folder and name; nil when the user leaves.
    func save(_ options: SaveOptions, over window: NSWindow? = nil) async -> URL? {
        await withCheckedContinuation { continuation in
            guard let palette = services?.palette else { return continuation.resume(returning: nil) }
            palette.show(page: savePage(options) { continuation.resume(returning: $0?.first) }, relativeTo: window)
        }
    }

    /// The open page, for an action the palette pushes in place.
    func openPage(_ options: OpenOptions, onFinish: @escaping ([URL]?) -> Void) -> PalettePageSpec {
        let filter = options.filter ?? PickerFilter(types: options.types.map(PickerFilter.FileType.init),
                                                    allowsAllFiles: options.allowsAllFiles)
        let mode = PickerMode(kind: .open(options.choose), allowsMultiple: options.allowsMultiple, filter: filter)
        let session = PickerSession(environment: environment(recents: recents.pickerPaths(options.recents)),
                                    title: options.title, prompt: options.prompt, onFinish: onFinish)
        return session.page(for: FolderPickerState(mode: mode, start: options.startDirectory ?? home))
    }

    func savePage(_ options: SaveOptions, onFinish: @escaping ([URL]?) -> Void) -> PalettePageSpec {
        let filter = options.filter ?? PickerFilter(types: options.types.map(PickerFilter.FileType.init))
        let session = PickerSession(environment: environment(recents: []), title: options.title, prompt: options.prompt,
                                    onFinish: onFinish)
        return session.page(for: FolderPickerState(mode: PickerMode(kind: .save, filter: filter), start: options.startDirectory ?? home),
                            query: options.name)
    }

    private var home: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

    private func environment(recents: [String]) -> PickerEnvironment {
        PickerEnvironment(home: home, recents: recents, locations: locations(), explainer: explainer)
    }

    /// Locations after Recent: the active window's workspace folders (its
    /// terminals' working directories), the standard places, then the
    /// user's `picker.pinned` folders. iCloud Drive shows when its folder
    /// exists (a stat of the folder itself, nothing inside it).
    private func locations() -> [PickerLocation] {
        var folders: [URL] = []
        for pane in services?.windows.active?.content?.panes.values.map({ $0 }) ?? [] {
            for tab in pane.pane.tabs where tab.kind == .pty {
                guard let cwd = tab.cwd, !cwd.isEmpty, cwd != home.path else { continue }
                folders.append(URL(fileURLWithPath: cwd, isDirectory: true))
            }
        }
        let iCloud = FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Mobile Documents").path)
        let pinned = (services?.settings?.snapshot.pickerPinned ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        return PickerLocation.ordered(workspace: folders, standard: PickerLocation.standard(home: home, iCloudDrive: iCloud), pinned: pinned)
    }
}
