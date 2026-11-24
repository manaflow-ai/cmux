#if os(iOS) && canImport(CmuxMobileLinkFFI)
import CmuxMobileAgentChat
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// Leo's 2026-11-24 ask, item 2 ("the initial load-in of allll my workspaces, it's kinda hard to
/// tell where i was"): a chat tab read part way up opens there again after a relaunch, from the
/// phone's own file, through Rust's last place (`LastPlaceMemory`, `cmux-mobile-last-place`).
@MainActor
@Suite struct LastPlaceRestoreTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("last-place-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("last-place.json")
    }

    @Test func aChatOpensWhereItWasReadAfterARelaunch() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        let anchor = ChatReadingAnchor(row: "u-turn-3", offset: 42)

        let before = LastPlaceMemory(fileURL: url)
        before.noteLocation(workspaceID: "ws-cmux", tabID: "t-claude", isChat: true)
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux")
        source.lastPlace = before
        source.surface("t-claude").onReadingAnchor?(anchor)
        before.flush()

        // A relaunch: a new memory reads the file, a new screen builds the tab.
        let after = LastPlaceMemory(fileURL: url)
        let rebuilt = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux")
        rebuilt.lastPlace = after
        #expect(rebuilt.surface("t-claude").restoreAnchor == anchor)
        // Another tab is not where the person was: it opens on its newest turn.
        #expect(rebuilt.surface("t-other").restoreAnchor == nil)
    }

    @Test func backOnTheNewestTurnOpensThereNextTime() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let memory = LastPlaceMemory(fileURL: url)
        memory.noteLocation(workspaceID: "ws-cmux", tabID: "t-claude", isChat: true)
        memory.noteReading(workspaceID: "ws-cmux", tabID: "t-claude", anchor: ChatReadingAnchor(row: "r1", offset: 3))
        memory.noteReading(workspaceID: "ws-cmux", tabID: "t-claude", anchor: nil)
        memory.flush()
        #expect(LastPlaceMemory(fileURL: url).readingAnchor(workspaceID: "ws-cmux", tabID: "t-claude") == nil)
    }

    @Test func aCorruptFileOpensNothingAndIsReplaced() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        let memory = LastPlaceMemory(fileURL: url)
        #expect(memory.readingAnchor(workspaceID: "ws-cmux", tabID: "t-claude") == nil)
        memory.noteLocation(workspaceID: "ws-cmux", tabID: "t-claude", isChat: true)
        memory.noteReading(workspaceID: "ws-cmux", tabID: "t-claude", anchor: ChatReadingAnchor(row: "r9", offset: 0))
        memory.flush()
        #expect(LastPlaceMemory(fileURL: url).readingAnchor(workspaceID: "ws-cmux", tabID: "t-claude") == ChatReadingAnchor(row: "r9", offset: 0))
    }
}
#endif
