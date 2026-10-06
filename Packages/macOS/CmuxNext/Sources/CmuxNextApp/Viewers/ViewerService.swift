import AppKit
import CmuxNextActions
import CmuxNextPalette

/// The viewers' shared parts (R89): the recents store, the cmux picker,
/// and the seams to the diff host and the code editor.
@MainActor
final class ViewerService {
    let recents: ViewerRecents
    let picker: CmuxPicker
    /// The diff host (S4): R89's open actions and the picker open diffs through it.
    var diffViewer: any DiffViewerOpening { diffPages }
    /// The file pages (diff-host S6, S7): markdown files open the markdown page, other files the
    /// code editor page, images and PDFs the browser tab's preview.
    var fileOpener: any FileOpening
    /// The diff open a picker choice started (one at a time; the next
    /// choice cancels it).
    private(set) var diffOpen: Task<Void, Never>?
    private weak var services: AppServices?
    /// The owner of the page services below (the app's services outlive the viewers).
    // crash-allow: AppServices owns this ViewerService for the app's whole life, so it outlives it.
    private unowned let owner: AppServices
    /// Diff viewer tabs (plans/cmux-next/diff-host.md S4).
    private(set) lazy var diffPages = DiffPageService(services: owner)
    /// Markdown page tabs (diff-host S6).
    private(set) lazy var markdownPages = FilePageService(services: owner, kind: .markdown)
    /// Code editor page tabs (diff-host S7).
    private(set) lazy var editorPages = FilePageService(services: owner, kind: .editor)

    init(services: AppServices, recents: ViewerRecents = ViewerRecents()) {
        self.services = services
        owner = services
        picker = CmuxPicker(services: services, recents: recents)
        fileOpener = FilePageOpener(services: services)
        self.recents = recents
    }

    /// The pane's folder: its selected terminal's cwd, else the cwd of its
    /// last terminal tab (a page or an agent tab has none).
    static func folder(of pane: PaneController) -> String? {
        if let cwd = pane.selectedTab?.cwd, !cwd.isEmpty { return cwd }
        return pane.pane.tabs.last { $0.kind == .pty && $0.cwd?.isEmpty == false }?.cwd
    }

    /// Where a picker for `pane` opens: its folder, else home.
    static func start(for pane: PaneController?) -> URL {
        let folder = pane.flatMap(folder(of:)) ?? NSHomeDirectory()
        return URL(fileURLWithPath: folder, isDirectory: true)
    }

    // MARK: Opening

    /// A diff tab for `directory` in `pane`; the diff host records the
    /// repository in its recents (`DiffRecents`, `cmux.diff.recents`).
    func openDiff(_ directory: String, in pane: PaneController, focus: Bool) async throws {
        try await diffViewer.openDiff(directory: directory, in: pane, focus: focus)
    }

    /// The picker's folder mode for the diff viewer.
    func diffPickerPage(for pane: PaneController) -> PalettePageSpec {
        picker.openPage(.init(choose: .folders, startDirectory: Self.start(for: pane), recents: [.diff])) { [weak self, weak pane] urls in
            guard let self, let pane, let folder = urls?.first else { return }
            // One diff open at a time: a newer choice cancels the one before.
            self.diffOpen?.cancel()
            self.diffOpen = Task { [weak self, weak pane] in
                guard let self, let pane else { return }
                do { try await self.openDiff(folder.path, in: pane, focus: true) } catch {
                    if !Task.isCancelled { self.showRefusal(Self.reason(error)) }
                }
                // A cancelled open leaves the handle to the one that replaced it.
                if !Task.isCancelled { self.diffOpen = nil }
            }
        }
    }

    /// The picker's file mode (`markdown`: Markdown only) at the pane's folder.
    func filePickerPage(for pane: PaneController?, markdown: Bool) -> PalettePageSpec {
        let options = CmuxPicker.OpenOptions(choose: .files, startDirectory: Self.start(for: pane),
                                             recents: markdown ? [.markdown] : [.file, .markdown],
                                             filter: markdown ? .markdown : nil)
        return picker.openPage(options) { [weak self, weak pane] urls in
            guard let self, let file = urls?.first else { return }
            self.openFile(file, in: pane, markdown: markdown)
        }
    }

    /// Opens `file` through ``fileOpener`` (a tab of `pane`: the markdown
    /// page, the code editor page or the browser tab's preview). False when
    /// it did not open (the refusal shows).
    @discardableResult
    func openFile(_ file: URL, in pane: PaneController?, markdown: Bool) -> Bool {
        if let reason = fileOpener.open(file, in: pane) {
            showRefusal(reason)
            return false
        }
        let kind: ViewerRecents.Kind = markdown || PickerFilter.markdown.accepts(file.lastPathComponent) ? .markdown : .file
        recents.record(file, as: kind)
        return true
    }

    // MARK: Host op of the Markdown empty screen (S6; the diff's is PickerDiffFolderChooser)

    /// `cmux.markdown.chooseFile {start?}`: the picker in file mode, Markdown only.
    func chooseMarkdownFile(start: String?) async -> String? {
        let options = CmuxPicker.OpenOptions(choose: .files, startDirectory: start.map { URL(fileURLWithPath: $0, isDirectory: true) },
                                             recents: [.markdown], filter: .markdown)
        return await picker.open(options)?.first?.path
    }

    static func reason(_ error: any Error) -> String {
        (error as? ActionFailure)?.message ?? error.localizedDescription
    }

    /// A refusal after the action returned (the picker answered later).
    func showRefusal(_ reason: String) {
        guard let services else { return }
        services.refusalHUD.show(reason, in: services.windows.active?.window ?? NSApp.keyWindow)
    }
}
