import AppKit
import CmuxNextDesign
import CmuxNextActions
import CmuxNextBookmarks
import Foundation
import CmuxNextWakeups
import CmuxNextCompat
import UniformTypeIdentifiers

/// Netscape HTML import and export (bookmarks.md section 3): open and save
/// panels for the UI, plain paths for the CLI. File IO runs off the main thread.
@MainActor
struct BookmarkFiles {
    let services: AppServices

    func chooseImport(profile: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.message = BookmarkAppStrings.importPrompt
        panel.beginForCmux { url in
            guard let url else { return }
            importFile(url, profile: profile)
        }
    }

    func chooseExport(profile: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = BookmarkAppStrings.exportFileName
        panel.beginForCmux { url in
            guard let url else { return }
            exportFile(url, profile: profile)
        }
    }

    /// Reads an HTML file into one "Imported" folder at the end of the bar.
    func importFile(_ url: URL, profile: String) {
        let service = services.bookmarks
        let registry = services.registry
        registry.track(Task { @MainActor in
            do {
                let html = try await Task.detached { try Self.read(url) }.value
                return Self.importHTML(html, into: service, profile: profile)
            } catch {
                return ActionWorkFailure(BookmarkAppStrings.failure(error))
            }
        })
    }

    /// Netscape HTML already in memory (an export archive's Bookmarks.html) into one
    /// "Imported" folder at the end of the bar; the failure, if any.
    func importHTML(_ html: String, profile: String) -> ActionWorkFailure? {
        Self.importHTML(html, into: services.bookmarks, profile: profile)
    }

    private static func importHTML(_ html: String, into service: BookmarkService, profile: String) -> ActionWorkFailure? {
        let document = NetscapeBookmarkReader.read(html)
        guard document.count > 0 else { return ActionWorkFailure(BookmarkAppStrings.importEmpty) }
        do {
            try service.apply(BookmarkImportPlan.file(document, title: BookmarkAppStrings.importedFolder,
                                                      barTitle: BookmarkStrings.barTitle), profile: profile)
            return nil
        } catch {
            return ActionWorkFailure(BookmarkAppStrings.failure(error))
        }
    }

    func exportFile(_ url: URL, profile: String) {
        let html = NetscapeBookmarkWriter.write(services.bookmarks.tree(profile), barTitle: BookmarkStrings.barTitle)
        let work = services.work
        services.registry.track(Task { @MainActor in
            do {
                // The person waits for the export they asked for: the files lane at userBlocking.
                try await work.run(.userBlocking, mayBlock: .files) { try Data(html.utf8).blockingWrite(to: url, options: .atomic) }
                return nil
            } catch {
                return ActionWorkFailure(BookmarkAppStrings.failure(error))
            }
        })
    }

    /// UTF-8, else Latin-1 (old Netscape files).
    nonisolated static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url) // concurrency-allow: nonisolated, called only from Task.detached in importFile
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
