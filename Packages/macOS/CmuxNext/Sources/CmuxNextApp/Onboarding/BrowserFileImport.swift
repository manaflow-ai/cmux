import AppKit
import CmuxNextActions
import CmuxNextBrowserImport
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups
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
        let reader = services.browserDataReader
        services.registry.track(Task { @MainActor in
            guard let source = await Self.chooseBrowser(), await Self.showSteps(source),
                  let urls = await services.viewers.picker.open(.init(choose: .files, allowsMultiple: true,
                                                                      types: [.commaSeparatedText, .html, .zip, .json],
                                                                      title: BrowserFileImportStrings.pickerTitle))
            else { return nil }
            var failures: [String] = []
            for url in urls {
                switch await reader.exportKind(of: url) {
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

    private static var scope: CmuxDialogScope { (NSApp.keyWindow ?? NSApp.mainWindow).map { .window($0) } ?? .app }

    /// The bundled browser-export-steps.json rows (Package.swift is frozen: the file stays an App resource).
    nonisolated static func exportRows() -> [BrowserExportSource] {
        let url = Bundle.module.url(forResource: "browser-export-steps", withExtension: "json")
        return url.flatMap { try? Data(blockingContentsOf: $0) }.map(BrowserExportSource.rows(in:)) ?? []
    }

    private static func chooseBrowser() async -> BrowserExportSource? {
        // This Mac's browsers first, the default web browser chosen (Launch Services only).
        let menu = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) {
            let ws = NSWorkspace.shared, https = URL(string: "https://example.com")
            let defaultID = https.flatMap { ws.urlForApplication(toOpen: $0) }.flatMap { Bundle(url: $0)?.bundleIdentifier }
            return BrowserExportMenu(rows: exportRows(), isInstalled: { ws.urlForApplication(withBundleIdentifier: $0) != nil },
                                     defaultBrowserBundleID: defaultID)
        }.value
        let sources = menu.rows
        guard let first = menu.selected else { return nil }
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
