import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextPalette
import Foundation
import Testing

/// Open Recovered Draft… (`file.openRecoveredDraft`, R96): the recovery drafts stay reachable
/// after their one launch toast. The action is bound and offers a palette page; the page lists
/// the store's drafts, newest first, and Return opens the chosen one through the store's
/// `restoreHandler`, the launch notice's Open. Opening never removes the draft.
@MainActor @Suite(.serialized)
struct RecoveredDraftPaletteTests {
    private static func directory() -> URL {
        URL(fileURLWithPath: "/tmp/rdp-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    private static func draft(_ name: String, savedAt seconds: TimeInterval) -> RecoveryDraft {
        let path = "/tmp/recovered-draft-palette/\(name)"
        return RecoveryDraft(id: QuitParticipantID.file(path: path), title: name,
                             savedAt: Date(timeIntervalSince1970: seconds), contents: Data("unsaved \(name)".utf8),
                             filePath: path)
    }

    private static func items(_ page: PalettePageSpec) async -> [PaletteItem] {
        var items: [PaletteItem] = []
        for provider in page.providers { items += await provider.items() }
        return items
    }

    @Test func theActionIsBoundAndOffersItsPage() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.registry.descriptor(for: "file.openRecoveredDraft") != nil)
        #expect(services.registry.unavailableReason(for: "file.openRecoveredDraft") == nil)
        let page = services.palette.sources.actionPages["file.openRecoveredDraft"]?()
        #expect(page?.id == RecoveredDraftPage.id)
        #expect(page?.title == PaletteStrings.recoveredDraftsTitle)
    }

    @Test func thePageListsTheDraftsNewestFirstAndOpensTheChosenOne() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = Self.draft("older.md", savedAt: 1000)
        let newer = Self.draft("newer.swift", savedAt: 2000)
        for draft in [older, newer] { await RecoveryDraftFiles.write(draft, in: directory, maxTotalBytes: .max) }
        let store = RecoveryDraftStore(directory: directory)
        var restored: [RecoveryDraft] = []
        store.restoreHandler = { restored.append($0) }

        let rows = await Self.items(RecoveredDraftPage(store: store).spec)
        #expect(rows.map(\.id) == [newer.id, older.id])
        #expect(rows.map(\.title) == ["newer.swift", "older.md"])
        #expect(rows.first?.subtitle == newer.filePath)
        let allEnabled = rows.allSatisfy(\.isEnabled)
        #expect(allEnabled)

        guard case .perform(let open) = try #require(rows.last).primary.effect else {
            Issue.record("a draft row opens the draft")
            return
        }
        open()
        #expect(restored == [older])
        #expect(await store.drafts().count == 2, "opening a draft removed it")
    }

    @Test func noDraftsListNothing() async {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryDraftStore(directory: directory)
        #expect(await Self.items(RecoveredDraftPage(store: store).spec).isEmpty)
    }

    /// Without an editor side to open drafts, rows show but cannot run.
    @Test func withoutARestoreHandlerTheRowsAreDisabled() async {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await RecoveryDraftFiles.write(Self.draft("notes.md", savedAt: 1000), in: directory, maxTotalBytes: .max)
        // The page holds its store weakly (the app's store lives as long as the app): keep it here.
        let store = RecoveryDraftStore(directory: directory)
        let rows = await Self.items(RecoveredDraftPage(store: store).spec)
        #expect(rows.count == 1)
        #expect(rows.first?.isEnabled == false)
    }
}
