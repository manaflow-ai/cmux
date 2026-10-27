import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextBrowserImport
import Foundation

/// The zip and history parts of Import from Another Browser… (cx-d0d.65):
/// Safari's Export Browsing Data zip and Google Takeout's Chrome export
/// (its zip holds Chrome/History.json and Chrome/Bookmarks.html).
/// An archive is read in memory (`ExportArchive`): only its
/// Bookmarks.html, History.json and Passwords.csv, never its credit cards;
/// no part is written to disk. History goes where the browser import puts
/// it: the import store and the profile's omnibar history.
extension BrowserFileImport {
    /// The failures, if any.
    func importArchive(_ url: URL, profile: String) async -> [String] {
        let archive: ExportArchive
        do {
            archive = try await Task.detached { try ExportArchive(contentsOf: url) }.value
        } catch {
            return [BrowserFileImportStrings.unreadable(url.lastPathComponent)]
        }
        guard !archive.isEmpty else { return [BrowserFileImportStrings.notAnExport(url.lastPathComponent)] }
        var failures: [String] = []
        let bookmarks = BookmarkFiles(services: services)
        for html in archive.bookmarksHTML {
            if let failure = bookmarks.importHTML(html, profile: profile) { failures.append(failure.message) }
        }
        for json in archive.historyJSON {
            failures += await importHistory(json, from: url, profile: profile)
        }
        // The archive holds the passwords in plain text: it goes to the Trash as a CSV would.
        for csv in archive.passwordCSVs {
            if let failure = await PasswordCSVFiles(services: services).importBytes(csv, profile: profile, trashing: url) {
                failures.append(failure.message)
            }
        }
        return failures
    }

    func importHistoryFile(_ url: URL, profile: String) async -> [String] {
        guard let data = await Task.detached(operation: { try? Data(contentsOf: url) }).value else {
            return [BrowserFileImportStrings.unreadable(url.lastPathComponent)]
        }
        return await importHistory(data, from: url, profile: profile)
    }

    private func importHistory(_ json: Data, from url: URL, profile: String) async -> [String] {
        guard let read = await Task.detached(operation: { ExportedHistory(json: json) }).value else {
            return [BrowserFileImportStrings.notAnExport(url.lastPathComponent)]
        }
        let browser = ImportBrowser(rawValue: read.format == .safari ? "safari" : "chrome")
        // One saved record per file, so a second export file adds to the first.
        var batch = ImportBatch(source: ImportSourceRecord(browser: browser, profileDirectory: "file:\(url.lastPathComponent)",
                                                           displayName: browser.displayName, proposedProfileID: profile,
                                                           targetProfileID: profile),
                                kinds: [.history])
        batch.history = read.entries
        do {
            try await SavingImportDestination.app(services).commit(batch)
        } catch {
            return [BrowserFileImportStrings.unreadable(url.lastPathComponent)]
        }
        Self.toast(services, id: "browser-history-imported", BrowserFileImportStrings.historyImported(read.entries.count))
        return []
    }
}
