public import AppKit
public import CmuxNextDesign

/// A page's file chooser as FILE_DIALOG carries it (`<input type=file>`, `showOpenFilePicker`,
/// `showSaveFilePicker`; CEFShim/src/shim_file_dialog.mm).
public nonisolated struct ChromiumFileDialogRequest: Equatable, Sendable {
    /// What the page asks for (the shim's `mode`).
    public enum Mode: Int32, Sendable {
        case open = 0
        case openMultiple = 1
        case folder = 2
        case save = 3
    }

    public let mode: Mode
    /// The page's `accept`: MIME types and ".ext" entries. cmux's panels allow every type, as
    /// WebKit's file input does (`WebFileInputAnswering`).
    public let acceptTypes: [String]
    /// Chromium's suggested path (a save's file name), or empty.
    public let defaultPath: String

    /// `mode` as the shim sends it; a mode it does not name opens one file, as the shim's default does.
    public init(mode: Int32, acceptTypes: [String], defaultPath: String) {
        self.mode = Mode(rawValue: mode) ?? .open
        self.acceptTypes = acceptTypes
        self.defaultPath = defaultPath
    }

    /// `multiple` of `cmux_shim_file_dialog_answer`: 0 keeps only the first path.
    var multiple: Int32 { mode == .openMultiple ? 1 : 0 }

    /// The answer's `paths`: the chosen files' absolute paths, one per line; nil (a cancel) for no
    /// choice. A path with a line break cannot be one line of the answer, so it is left out.
    static func paths(_ urls: [URL]?) -> String? {
        let paths = (urls ?? []).filter(\.isFileURL).map { $0.path(percentEncoded: false) }
            .filter { $0.hasPrefix("/") && !$0.contains("\n") }
        return paths.isEmpty ? nil : paths.joined(separator: "\n")
    }
}

/// Shows the picker for a page's file chooser in cmux: ``ChromiumFileDialogPanels`` in the app, a
/// stand-in in tests (a test host cannot make an `NSOpenPanel` without its view service).
@MainActor
public protocol ChromiumFileDialogAnswering: AnyObject {
    /// Shows the picker for chooser `dialog`'s `request`, as a sheet on `window` (else as its own
    /// window), and calls `completion` exactly once: the chosen files, or nil when the person
    /// cancelled or no picker could be shown.
    func answerFileDialog(_ dialog: Int32, request: ChromiumFileDialogRequest, window: NSWindow?,
                          completion: @escaping @MainActor ([URL]?) -> Void)
    /// Takes down chooser `dialog`'s picker, if it shows, and no other; its completion then runs
    /// with nil.
    func endFileDialog(_ dialog: Int32)
}

/// cmux's pickers for a page's file chooser: the app's made-ahead open panel (``MadeAheadOpenPanel``,
/// shared with every WebKit file input) for a file or folder, and a save panel for a save, each as a
/// sheet on the page's window.
public final class ChromiumFileDialogPanels: ChromiumFileDialogAnswering {
    private let openPanel: MadeAheadOpenPanel
    /// The picker showing for each chooser, by Chromium's dialog id. Two choosers can share a
    /// window (AppKit queues the second sheet) or have none, so a window names no one picker.
    private var shown: [Int32: NSSavePanel] = [:]

    /// - Parameter openPanel: The app's made-ahead panel (`AppServices.openPanel`).
    public init(openPanel: MadeAheadOpenPanel) {
        self.openPanel = openPanel
    }

    public func answerFileDialog(_ dialog: Int32, request: ChromiumFileDialogRequest, window: NSWindow?,
                                 completion: @escaping @MainActor ([URL]?) -> Void) {
        guard shown[dialog] == nil, let panel = panel(for: request) else { return completion(nil) }
        shown[dialog] = panel
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.shown[dialog] = nil
            completion(response == .OK ? Self.chosen(in: panel) : nil)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    public func endFileDialog(_ dialog: Int32) {
        shown[dialog]?.cancel(nil)
    }

    /// A panel set up for `request`; nil when the open panel came back dead (``MadeAheadOpenPanel/panel()``).
    private func panel(for request: ChromiumFileDialogRequest) -> NSSavePanel? {
        guard request.mode != .save else {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            let suggested = URL(filePath: request.defaultPath)
            if !request.defaultPath.isEmpty { panel.nameFieldStringValue = suggested.lastPathComponent }
            if request.defaultPath.hasPrefix("/") { panel.directoryURL = suggested.deletingLastPathComponent() }
            return panel
        }
        guard let panel = openPanel.panel() else { return nil }
        panel.allowsMultipleSelection = request.mode == .openMultiple
        panel.canChooseDirectories = request.mode == .folder
        panel.canChooseFiles = request.mode != .folder
        panel.resolvesAliases = true
        return panel
    }

    private static func chosen(in panel: NSSavePanel) -> [URL]? {
        if let open = panel as? NSOpenPanel { return open.urls }
        return panel.url.map { [$0] }
    }
}
