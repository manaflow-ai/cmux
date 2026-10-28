import AppKit
import CmuxNextActions
import CmuxNextBrowserImport
import CmuxNextDesign
import CmuxNextWakeups
import Foundation
import UniformTypeIdentifiers
import CmuxNextCompat

/// Import from Another Browser… (`browser.importFromFiles`, cx-d0d.65): cmux
/// reads no other browser's own data here. The person picks the browser,
/// sees its export steps, and picks the exported files in the cmux picker;
/// each file goes by its content to the password CSV import or the bookmarks
/// HTML import. Person-only, like the CSV import: an agent cannot put the
/// picker in front of the person.
@MainActor
struct BrowserFileImport {
    let services: AppServices

    private static let browserField = "browser"

    func run(profile: String) {
        let services = services
        // main-hop-allow: the action's tracked work awaits the person's own sheets and picker (main-actor AppKit UI), then each file's import; each step runs in its reply's resume
        services.registry.track(Task { @MainActor in
            guard let source = await Self.chooseBrowser(work: services.work), await Self.showSteps(source),
                  let urls = await services.viewers.picker.open(.init(choose: .files, allowsMultiple: true,
                                                                      types: [.commaSeparatedText, .html, .zip, .json],
                                                                      title: BrowserFileImportStrings.pickerTitle))
            else { return nil }
            var failures: [String] = []
            for url in urls {
                switch await Task.detached(operation: { Self.kind(of: url) }).value {
                case .bookmarks?: BookmarkFiles(services: services).importFile(url, profile: profile)
                case .passwords?:
                    if let failure = await PasswordCSVFiles(services: services).importFile(url, profile: profile) {
                        failures.append(failure.message)
                    }
                case .archive?: failures += await importArchive(url, profile: profile)
                case .history?: failures += await importHistoryFile(url, profile: profile)
                case nil: failures.append(BrowserFileImportStrings.notAnExport(url.lastPathComponent))
                }
            }
            guard !failures.isEmpty else { return nil }
            let message = failures.joined(separator: " ")
            // A palette or menu run waits for nothing: the person sees the failure here.
            Self.toast(services, id: "browser-file-import-failed", message)
            return ActionWorkFailure(message)
        })
    }

    /// A toast on the app window (after the picker the key window is the palette's panel).
    static func toast(_ services: AppServices, id: String, _ message: String) {
        guard let window = services.windows.active?.window ?? NSApp.mainWindow else { return }
        _ = CmuxToastCenter.shared.show(CmuxToast(id: id, message: message, duration: .seconds(12)), in: window)
    }

    nonisolated enum FileKind: Sendable {
        case passwords
        case bookmarks
        /// A zip: Safari's Export Browsing Data, or Google Takeout.
        case archive
        /// Safari's History.json or Takeout's Chrome history.
        case history
    }

    /// By content, not name: a zip archive; JSON with a history list; a
    /// Netscape bookmarks file is HTML with a `<DL>` list; any other text
    /// with commas goes to the CSV import, which names a file without
    /// website and password columns.
    nonisolated static func kind(of url: URL) -> FileKind? {
        guard let handle = try? FileHandle.blockingForReading(from: url) else { return nil }
        defer { try? handle.close() }
        let bytes = (try? handle.blockingRead(upToCount: 4096)) ?? Data()
        if ExportArchive.isArchive(bytes) { return .archive }
        let head = String(decoding: bytes, as: UTF8.self)
        let text = head.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        if ExportedHistory.looksLikeHistory(String(text)) { return .history }
        if text.first == "<" {
            let upper = text.uppercased()
            return upper.contains("NETSCAPE-BOOKMARK-FILE") || upper.contains("<DL") ? .bookmarks : nil
        }
        return text.contains(",") ? .passwords : nil
    }

    private static var scope: CmuxDialogScope { (NSApp.keyWindow ?? NSApp.mainWindow).map { .window($0) } ?? .app }

    /// The browser the person picks; its rows are read on the files lane while the action waits.
    private static func chooseBrowser(work: BackgroundWork) async -> BrowserExportSource? {
        let sources = (try? await work.run(.userBlocking, mayBlock: .files) { BrowserExportSource.loadBundled() }) ?? []
        guard let first = sources.first else { return nil }
        let spec = CmuxDialogSpec(
            title: BrowserFileImportStrings.title, lines: [BrowserFileImportStrings.message],
            fields: [.choice(id: browserField, label: BrowserFileImportStrings.browserLabel,
                             options: sources.map { CmuxDialogOption(label: $0.name, value: $0.id) }, selected: first.id)],
            buttons: [CmuxDialogButton(id: "cancel", title: PasswordCSVGuideStrings.cancel, role: .cancel),
                      CmuxDialogButton(id: "continue", title: PasswordCSVGuideStrings.continueTitle, role: .default)],
            identifier: "cmux.dialog.importFiles.browser")
        let answer = await CmuxDialogCenter.shared.present(spec, in: scope)
        guard answer.button == "continue", !answer.isDismissal, let id = answer.values[browserField]?.text else { return nil }
        return sources.first { $0.id == id }
    }

    /// Whether the person went on to choose the files.
    private static func showSteps(_ source: BrowserExportSource) async -> Bool {
        let spec = CmuxDialogSpec(
            title: BrowserFileImportStrings.stepsTitle(source.name),
            lines: BrowserFileImportStrings.steps(source) + [BrowserFileImportStrings.lastStep],
            buttons: [CmuxDialogButton(id: "cancel", title: PasswordCSVGuideStrings.cancel, role: .cancel),
                      CmuxDialogButton(id: "choose", title: BrowserFileImportStrings.chooseFiles, role: .default)],
            identifier: "cmux.dialog.importFiles.steps")
        let answer = await CmuxDialogCenter.shared.present(spec, in: scope)
        return answer.button == "choose" && !answer.isDismissal
    }
}
