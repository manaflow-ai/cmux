import AppKit
import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextBrowserImport
import CmuxNextDesign
import Foundation

/// Bookmarks from another browser (decision BOOKMARKS-IMPORT-EVERY-BROWSER
/// I4/I5), one path for File > Import, the palette, the Bookmark Manager and
/// the CLI. Only browsers found on this Mac are offered, each profile on its
/// own; every profile goes into one "Imported from <Browser> (<profile>)"
/// folder on the Bookmarks Bar (a repeat import replaces that folder), the
/// same URL twice in one folder is kept once, a toast shows the counts, and
/// its Undo (or Cmd-Z) puts the bar back as it was: one undo step.
///
/// Security: reads run in this process, off the main thread, read-only
/// (SQLite from a private copy); no Keychain access; the detector reads only
/// browser data folders under ~/Library, never Documents, Desktop or Downloads.
@MainActor
struct BookmarkBrowserImport {
    let services: AppServices

    /// What one import did, for the summary and the undo.
    struct Outcome {
        var added = 0
        var duplicates = 0
        /// The source names whose bookmarks were imported.
        var sources: [String] = []
        /// Sources that could not be read.
        var failed: [String] = []
        var undo: [Undo] = []
    }

    /// How to put one source's folder back.
    struct Undo {
        var profile: String
        var sourceKey: String
        /// The folder the import replaced; nil when the import created it.
        var previous: BookmarkDraft?
    }

    /// Browsers found on this Mac whose bookmarks a person can import:
    /// readable, blocked by Full Disk Access (Safari), or exported by the
    /// browser itself. Only browsers and enterprise browsers are listed.
    nonisolated static func sources(environment: ImportEnvironment) -> [BrowserSource] {
        BrowserSourceDetector(environment: environment).detect(ImportBrowser.allCases.filter(\.listsForBookmarks)).compactMap { source in
            var source = source
            source.profiles = source.profiles.filter { $0.availability(of: .bookmarks) != .absent }
            return source.profiles.isEmpty ? nil : source
        }
    }

    nonisolated static func liveEnvironment() -> ImportEnvironment {
        ImportEnvironment.live { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// The folder title for one source profile.
    static func folderTitle(_ profile: BrowserSourceProfile) -> String {
        folderTitle(browser: profile.browser, profileName: showsProfileName(profile) ? profile.displayName : nil)
    }

    static func folderTitle(browser: ImportBrowser, profileName: String?) -> String {
        guard let profileName, !profileName.isEmpty else { return BookmarkAppStrings.importedFrom(browser.displayName) }
        return BookmarkAppStrings.importedFrom(browser.displayName, profile: profileName)
    }

    /// One-store browsers (Safari, Opera, private stores) have no profile name worth showing.
    static func showsProfileName(_ profile: BrowserSourceProfile) -> Bool {
        !(profile.directoryName.isEmpty || profile.browser.family == .safari || profile.browser.family.isPrivateStore)
    }

    // MARK: Person path: the picker

    /// Finds the browsers off the main thread, then asks which profiles to import.
    func choose(profile target: String, window: NSWindow?) {
        let services = services
        // task-owner: one-shot detection for a person's picker; ends when the dialog shows
        Task { @MainActor in
            let sources = await Task.detached { Self.sources(environment: Self.liveEnvironment()) }.value
            guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
            present(sources, target: target, in: window, services: services)
        }
    }

    private func present(_ sources: [BrowserSource], target: String, in window: NSWindow, services: AppServices) {
        let readable = sources.flatMap(\.profiles).filter { $0.availability(of: .bookmarks) == .available }
        let blocked = sources.filter { $0.profiles.contains { $0.availability(of: .bookmarks) == .needsFullDiskAccess } }
        let exportOnly = sources.filter { $0.profiles.allSatisfy { $0.availability(of: .bookmarks) == .unsupported(.exportFromSource) } }
        var lines: [String] = [readable.isEmpty ? BookmarkAppStrings.importNoBrowser : BookmarkAppStrings.importLead]
        lines += blocked.map { BookmarkAppStrings.importNeedsFullDiskAccess($0.browser.displayName) }
        lines += exportOnly.map { BookmarkAppStrings.importExportFirst($0.browser.displayName) }
        // Every readable profile starts checked; the person unchecks what stays out.
        let fields = readable.map { CmuxDialogField.check(id: $0.id, title: Self.pickerTitle($0), on: true) }
        var buttons: [CmuxDialogButton] = [.cancel(), CmuxDialogButton(id: "file", title: BookmarkAppStrings.importChooseFile)]
        if !blocked.isEmpty { buttons.append(CmuxDialogButton(id: "privacy", title: BookmarkAppStrings.importOpenPrivacy)) }
        if !readable.isEmpty { buttons.append(CmuxDialogButton(id: "import", title: BookmarkAppStrings.importConfirm, role: .default)) }
        let spec = CmuxDialogSpec(title: BookmarkAppStrings.importTitle, lines: lines, fields: fields, buttons: buttons,
                                  identifier: "cmux.dialog.bookmarks.importBrowser")
        CmuxDialogCenter.shared.present(spec, in: .window(window)) { answer in
            switch answer.button {
            case "import":
                let picked = readable.filter { answer.isOn($0.id) }
                guard !picked.isEmpty else { return }
                let work = Self(services: services)
                // task-owner: one import the person started; ends with its summary toast
                Task { @MainActor in
                    let outcome = await work.run(picked, target: target)
                    work.announce(outcome, in: window)
                }
            case "file":
                BookmarkFiles(services: services).chooseImport(profile: target)
            case "privacy":
                Self.openFullDiskAccessSettings()
            default:
                return
            }
        }
    }

    /// The readable profiles a CLI or agent call names: `browser` is a
    /// registry id or a product name, `source` a profile folder or name
    /// (nil: every readable profile of that browser). Case does not matter.
    nonisolated static func match(_ sources: [BrowserSource], browser: String, source: String?) -> [BrowserSourceProfile] {
        let wanted = browser.lowercased()
        let profiles = sources.filter { $0.browser.rawValue.lowercased() == wanted || $0.browser.displayName.lowercased() == wanted }
            .flatMap(\.profiles).filter { $0.availability(of: .bookmarks) == .available }
        guard let source, !source.isEmpty else { return profiles }
        let name = source.lowercased()
        return profiles.filter { $0.directoryName.lowercased() == name || $0.displayName.lowercased() == name }
    }

    static func pickerTitle(_ profile: BrowserSourceProfile) -> String {
        showsProfileName(profile) ? "\(profile.browser.displayName) (\(profile.displayName))" : profile.browser.displayName
    }

    /// System Settings > Privacy & Security > Full Disk Access.
    static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Import

    /// Reads each profile off the main thread, then applies all of them as
    /// one undo step on `target`'s bookmarks.
    func run(_ profiles: [BrowserSourceProfile], target: String) async -> Outcome {
        var outcome = Outcome()
        for profile in profiles {
            let read = await Task.detached { () -> [ImportedBookmark]? in try? BrowserImporter.readBookmarks(profile) }.value
            guard let bookmarks = read else {
                outcome.failed.append(Self.pickerTitle(profile))
                continue
            }
            let items = bookmarks.map { BookmarkImportItem(title: $0.title, url: $0.url, folderPath: $0.folderPath, created: $0.dateAdded) }
            do {
                let undo = try services.bookmarks.importSource(items, title: Self.folderTitle(profile), sourceKey: profile.id, profile: target)
                outcome.added += undo.result.added
                outcome.duplicates += undo.result.duplicates
                outcome.sources.append(Self.pickerTitle(profile))
                outcome.undo.append(undo.undo)
            } catch {
                outcome.failed.append(Self.pickerTitle(profile))
            }
        }
        return outcome
    }

    /// The summary toast; its Undo puts every imported folder back.
    func announce(_ outcome: Outcome, in window: NSWindow?) {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        var parts: [String] = []
        if !outcome.sources.isEmpty {
            parts.append(BookmarkAppStrings.importSummary(added: outcome.added, duplicates: outcome.duplicates,
                                                          sources: outcome.sources.joined(separator: ", ")))
        }
        if !outcome.failed.isEmpty { parts.append(BookmarkAppStrings.importFailed(outcome.failed.joined(separator: ", "))) }
        guard !parts.isEmpty else { return }
        let undo = outcome.undo
        let toast = CmuxToast(id: "bookmarks-import", message: parts.joined(separator: " "),
                              action: undo.isEmpty ? nil : .undo(), duration: .seconds(10))
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        let bookmarks = services.bookmarks
        handle.onAction = { bookmarks.undoImport(undo) }
    }
}

extension BookmarkService {
    /// Applies one source's import and returns how to undo it.
    func importSource(_ items: [BookmarkImportItem], title: String, sourceKey: String, profile: String) throws
        -> (result: BookmarkImportPlan.SourceImport, undo: BookmarkBrowserImport.Undo) {
        let previous = tree(profile).folder(sourceKey: sourceKey).flatMap { tree(profile).draft(of: $0.id) }
        let result = BookmarkImportPlan.sourceImport(title: title, sourceKey: sourceKey, items: items)
        try apply(result.operation, profile: profile)
        return (result, BookmarkBrowserImport.Undo(profile: profile, sourceKey: sourceKey, previous: previous))
    }

    /// Puts each source's folder back as it was before the import, newest first.
    func undoImport(_ steps: [BookmarkBrowserImport.Undo]) {
        for step in steps.reversed() {
            do {
                if let previous = step.previous {
                    try apply(.importDrafts(parent: BookmarkRoot.bar.rawValue, index: nil, sourceKey: step.sourceKey, replace: true,
                                            drafts: [previous]), profile: step.profile)
                } else if let folder = tree(step.profile).folder(sourceKey: step.sourceKey) {
                    try apply(.delete(id: folder.id), profile: step.profile)
                }
            } catch {
                logger.error("undo bookmarks import \(step.sourceKey, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }
}
