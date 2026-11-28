import AppKit
import CmuxNextDesign
import CmuxNextActions
import CmuxNextBookmarks
import Foundation
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
                let document = NetscapeBookmarkReader.read(html)
                guard document.count > 0 else { return ActionWorkFailure(BookmarkAppStrings.importEmpty) }
                try service.apply(BookmarkImportPlan.file(document, title: BookmarkAppStrings.importedFolder,
                                                          barTitle: BookmarkStrings.barTitle), profile: profile)
                return nil
            } catch {
                return ActionWorkFailure(BookmarkAppStrings.failure(error))
            }
        })
    }

    func exportFile(_ url: URL, profile: String) {
        let html = NetscapeBookmarkWriter.write(services.bookmarks.tree(profile), barTitle: BookmarkStrings.barTitle)
        services.registry.track(Task { @MainActor in
            do {
                try await Task.detached { try Data(html.utf8).write(to: url, options: .atomic) }.value
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
