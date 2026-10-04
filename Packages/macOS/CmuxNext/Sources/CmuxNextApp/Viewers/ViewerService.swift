import AppKit
import CmuxNextActions
import CmuxNextPalette

/// Until cmux.editor: `file.open` with the path, in a tab of the pane.
@MainActor
final class BrowserTabFileOpener: FileOpening {
    private unowned let registry: ActionRegistry

    init(registry: ActionRegistry) {
        self.registry = registry
    }

    func open(_ file: URL, in pane: PaneController?) -> String? {
        var invocation = ActionInvocation(arguments: ["path": .string(file.path), "where": .string("tab")])
        if let pane { invocation.target = ActionTargetRef(kind: .pane, id: pane.paneKey) }
        let registry = registry
        return registry.capturingRefusal { _ = registry.perform("file.open", invocation: invocation) }
    }
}

/// The viewers' shared parts (R89): the recents store, the cmux picker,
/// and the seams to the diff host and the code editor.
@MainActor
final class ViewerService {
    let recents: ViewerRecents
    private(set) lazy var picker = CmuxPicker(services: services, recents: recents)
    var diffViewer: any DiffViewerOpening = UnavailableDiffViewer()
    private(set) lazy var fileOpener: any FileOpening = BrowserTabFileOpener(registry: services.registry)
    private unowned let services: AppServices

    init(services: AppServices, recents: ViewerRecents = ViewerRecents()) {
        self.services = services
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

    /// A diff tab for `directory` in `pane`; the folder joins the recents.
    func openDiff(_ directory: String, in pane: PaneController, focus: Bool) async throws {
        try await diffViewer.openDiff(directory: directory, in: pane, focus: focus)
        recents.record(URL(fileURLWithPath: directory, isDirectory: true), as: .diff)
    }

    /// The picker's folder mode for the diff viewer.
    func diffPickerPage(for pane: PaneController) -> PalettePageSpec {
        picker.openPage(.init(choose: .folders, startDirectory: Self.start(for: pane), recents: [.diff])) { [weak self, weak pane] urls in
            guard let self, let pane, let folder = urls?.first else { return }
            Task {
                do { try await self.openDiff(folder.path, in: pane, focus: true) } catch { self.showRefusal(Self.reason(error)) }
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

    /// Opens `file` through ``fileOpener`` (a tab of `pane`). A Markdown
    /// file opens there too until the Markdown page (S6) lands. False when
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

    // MARK: Host ops of the webviews empty screens (S4, S6)

    /// `cmux.diff.chooseFolder {start?}`: the picker in folder mode, the
    /// chosen folder's path or nil (cancel).
    func chooseFolder(start: String?) async -> String? {
        let options = CmuxPicker.OpenOptions(choose: .folders, startDirectory: start.map { URL(fileURLWithPath: $0, isDirectory: true) },
                                             recents: [.diff])
        return await picker.open(options)?.first?.path
    }

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
        services.refusalHUD.show(reason, in: services.windows.active?.window ?? NSApp.keyWindow)
    }
}
