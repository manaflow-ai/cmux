import AppKit
import CmuxNextActions
import CmuxNextDesign
import Foundation
import UniformTypeIdentifiers

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
        services.registry.track(Task { @MainActor in
            guard let source = await Self.chooseBrowser(), await Self.showSteps(source),
                  let urls = await services.viewers.picker.open(.init(choose: .files, allowsMultiple: true,
                                                                      types: [.commaSeparatedText, .html],
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
                case nil: failures.append(BrowserFileImportStrings.notAnExport(url.lastPathComponent))
                }
            }
            guard !failures.isEmpty else { return nil }
            let message = failures.joined(separator: " ")
            // A palette or menu run waits for nothing: the person sees the failure here.
            if let window = services.windows.active?.window ?? NSApp.mainWindow {
                _ = CmuxToastCenter.shared.show(CmuxToast(id: "browser-file-import-failed", message: message, duration: .seconds(12)),
                                            in: window)
            }
            return ActionWorkFailure(message)
        })
    }

    nonisolated enum FileKind: Sendable {
        case passwords
        case bookmarks
    }

    /// By content, not name: a Netscape bookmarks file is HTML with a `<DL>`
    /// list; any other text with commas goes to the CSV import, which names
    /// a file without website and password columns.
    nonisolated static func kind(of url: URL) -> FileKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        let text = head.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        if text.first == "<" {
            let upper = text.uppercased()
            return upper.contains("NETSCAPE-BOOKMARK-FILE") || upper.contains("<DL") ? .bookmarks : nil
        }
        return text.contains(",") ? .passwords : nil
    }

    private static var scope: CmuxDialogScope { (NSApp.keyWindow ?? NSApp.mainWindow).map { .window($0) } ?? .app }

    private static func chooseBrowser() async -> BrowserExportSource? {
        let sources = BrowserExportSource.all
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
