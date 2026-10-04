import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import Foundation
import Testing

/// The viewers' open actions and shared parts (R89): each action is in the
/// catalog for the palette, the CLI and the File menu, bound with a real
/// handler, and served in the palette as the cmux picker; the recents store
/// and the seams to the diff host and the code editor.
@MainActor @Suite struct ViewerActionsTests {
    static let actions: [ActionID] = ["openDiffViewer", "palette.openDirectoryDiffViewer", "openMarkdownFile", "file.open"]

    @Test func everyViewerActionIsOfferedByThePaletteTheCLIAndTheFileMenu() throws {
        for id in Self.actions {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id }, "\(id) is not in the catalog")
            #expect(descriptor.surfaces.contains(.palette), "\(id)")
            #expect(descriptor.surfaces.contains(.menu), "\(id)")
            #expect(descriptor.mainMenu == .file, "\(id)")
            #expect(descriptor.cliName != nil, "\(id)")
            #expect(descriptor.surfacePlan.cli == .offered, "\(id)")
        }
        let titles = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id, $0.title) })
        #expect(titles["palette.openDirectoryDiffViewer"] == "Open Diff Viewer in Folder…")
        #expect(titles["openMarkdownFile"] == "Open Markdown File…")
        #expect(titles["file.open"] == "Open File…")
    }

    @Test func pathsAreOptionalSoTheMenuAndShortcutAskWithThePicker() throws {
        for id: ActionID in ["file.open", "openMarkdownFile"] {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
            let path = try #require(descriptor.arguments.first { $0.name == "path" }, "\(id)")
            #expect(!path.isRequired, "\(id)")
        }
    }

    @Test func everyViewerActionIsBoundAndAvailable() {
        let services = ActionBindingCoverageTests.boundServices()
        for id in Self.actions {
            #expect(services.registry.isBound(id), "\(id)")
            #expect(services.registry.unavailableReason(for: id) == nil, "\(id): \(services.registry.unavailableReason(for: id) ?? "")")
        }
    }

    @Test func thePaletteServesThePickersInPlace() {
        let services = ActionBindingCoverageTests.boundServices()
        for id: ActionID in ["palette.openDirectoryDiffViewer", "openMarkdownFile", "file.open"] {
            #expect(services.palette.sources.actionPages[id] != nil, "\(id)")
        }
        let page = services.viewers.filePickerPage(for: nil, markdown: true)
        #expect(page.id == "picker" || page.id == "picker.explainer")
        #expect(page.hierarchy != nil)
    }

    /// One path for the open actions: R89's handlers, which open the diff
    /// through S4's DiffPageService, and the empty state's folder chooser is
    /// the cmux picker, not the system panel.
    @Test func theDiffOpensThroughTheDiffHostAndItsChooserIsThePicker() {
        let services = ActionBindingCoverageTests.boundServices()
        #expect(services.viewers.diffViewer === services.diffPages)
        #expect(services.diffPages.chooser is PickerDiffFolderChooser)
    }

    // MARK: Recents

    @Test func recentsMoveToTheFrontKeepTheirSourceAndAnswerTheHostOps() throws {
        let defaults = try #require(UserDefaults(suiteName: "viewer-recents-\(UUID().uuidString)"))
        var clock = Date(timeIntervalSince1970: 1_000)
        let recents = ViewerRecents(defaults: defaults, now: { clock })
        recents.record(URL(fileURLWithPath: "/repo/a", isDirectory: true), as: .diff, source: "staged", branch: "main")
        clock = Date(timeIntervalSince1970: 2_000)
        recents.record(URL(fileURLWithPath: "/repo/b", isDirectory: true), as: .diff)
        clock = Date(timeIntervalSince1970: 3_000)
        recents.record(URL(fileURLWithPath: "/repo/a/", isDirectory: true), as: .diff)
        #expect(recents.paths(.diff) == ["/repo/a", "/repo/b"])
        let answer = recents.hostOpValue(.diff, home: "/Users/ada")
        #expect(answer["home"] as? String == "/Users/ada")
        let items = try #require(answer["items"] as? [[String: Any]])
        #expect(items.first?["path"] as? String == "/repo/a")
        #expect(items.first?["name"] as? String == "a")
        #expect(items.first?["openedAt"] as? Double == 3_000_000, "ms since the epoch")
        #expect(items.first?["source"] as? String == "staged", "a later open keeps the last source")
        #expect(items.first?["branch"] as? String == "main")
        #expect(items.last?["source"] == nil)
        // Persisted: a new store reads the same list.
        #expect(ViewerRecents(defaults: defaults).paths(.diff) == ["/repo/a", "/repo/b"])
    }

    @Test func thePickerReadsFoldersWithATrailingSlashNewestFirstAcrossKinds() throws {
        let defaults = try #require(UserDefaults(suiteName: "viewer-recents-\(UUID().uuidString)"))
        var clock = Date(timeIntervalSince1970: 1)
        let recents = ViewerRecents(defaults: defaults, now: { clock })
        recents.record(URL(fileURLWithPath: "/n/a.md"), as: .markdown)
        clock = Date(timeIntervalSince1970: 2)
        recents.record(URL(fileURLWithPath: "/repo", isDirectory: true), as: .diff)
        clock = Date(timeIntervalSince1970: 3)
        recents.record(URL(fileURLWithPath: "/n/main.swift"), as: .file)
        #expect(recents.pickerPaths([.diff, .markdown, .file]) == ["/n/main.swift", "/repo/", "/n/a.md"])
        for index in 0..<30 { recents.record(URL(fileURLWithPath: "/f/\(index)"), as: .file) }
        #expect(recents.paths(.file).count == ViewerRecents.limit)
    }

    /// cmux-next has no file viewer surface: until the code editor page
    /// (cmux.editor) lands, a chosen file opens as `file.open` opens it.
    @Test func aChosenFileOpensThroughTheEditorSeam() throws {
        let services = ActionBindingCoverageTests.boundServices()
        #expect(services.viewers.fileOpener is BrowserTabFileOpener)
        let reason = services.viewers.fileOpener.open(URL(fileURLWithPath: "/nope-\(UUID().uuidString)/a.md"), in: nil)
        #expect(reason?.isEmpty == false, "a missing file is refused by file.open, not dropped")
    }
}
