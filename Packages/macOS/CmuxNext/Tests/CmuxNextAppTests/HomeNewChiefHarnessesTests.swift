import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import Foundation
import Testing

/// Lawrence 2026-10-23: "show all possible harnesses by default". New Chief offers the official
/// engines and every harness this Mac's acpmux lists; one that is not installed, signed out or
/// unavailable here stays in the list, marked, and the sheet says what it needs.
@MainActor
@Suite struct HomeNewChiefHarnessesTests {
    private static let listed = [
        HomeChiefListedHarness(id: "claude", name: "Claude Code"),
        HomeChiefListedHarness(id: "codex", name: "Codex", signedOut: true),
        HomeChiefListedHarness(id: "opencode", name: "OpenCode"),
        HomeChiefListedHarness(id: "gemini", name: "Gemini CLI", unavailable: "gemini: command not found"),
    ]

    @Test func everyHarnessIsAChoiceAndTheOnesNotSetUpAreMarked() {
        let choices = HomeChiefHarnessChoice.choices(listed: Self.listed)
        #expect(choices.map(\.id) == ["claude", "codex", "muse", "unii", "opencode", "gemini"])
        let state = Dictionary(uniqueKeysWithValues: choices.map { ($0.id, $0.state) })
        #expect(state["claude"] == .ready)
        #expect(state["codex"] == .signedOut)
        #expect(state["muse"] == .notInstalled)
        // UniiChat is acpmux's built-in: listed or not, it is never "not installed".
        #expect(state["unii"] == .ready)
        #expect(state["opencode"] == .ready)
        #expect(state["gemini"] == .unavailable)
        #expect(choices.first { $0.id == "opencode" }?.title == "OpenCode")
    }

    @Test func theSheetListsEveryHarnessAndCreatesOnTheOnePicked() async throws {
        let sheet = HomeNewChiefSheet()
        _ = sheet.view
        sheet.show(HomeChiefHarnessChoice.choices(listed: Self.listed))
        let ids = sheet.backend.itemArray.compactMap { $0.representedObject as? String }
        #expect(ids == ["claude", "codex", "muse", "unii", "opencode", "gemini"])
        let muse = try #require(sheet.backend.itemArray.first { $0.representedObject as? String == "muse" })
        #expect(muse.title != ChiefBackend.muse.title && muse.title.hasPrefix(ChiefBackend.muse.title))
        sheet.backend.select(muse)
        sheet.backendChanged(sheet.backend)
        #expect(!sheet.backendHint.isHidden)
        let (asked, ask) = AsyncStream<ChiefBackend>.makeStream()
        sheet.onCreate = { _, backend in
            ask.yield(backend)
            return .offline
        }
        sheet.name.stringValue = "Scout"
        let index = try #require(sheet.backend.itemArray.firstIndex { $0.representedObject as? String == "opencode" })
        sheet.backend.selectItem(at: index)
        #expect(sheet.chosenBackend.id == "opencode")
        #expect(sheet.chosenBackend.createsOnThisMac)
        sheet.submit()
        var iterator = asked.makeAsyncIterator()
        #expect(try #require(await iterator.next()).id == "opencode")
    }
}
