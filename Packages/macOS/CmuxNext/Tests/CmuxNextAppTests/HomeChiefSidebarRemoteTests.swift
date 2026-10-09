import AppKit
import Foundation
import Testing
@testable import CmuxNextApp

/// The Chief Settings panel shows and sets the engine of the brain that
/// answers this Chief: this Mac's files for a local Chief, the paired
/// server's brain (`chief.engine.get` / `chief.engine.set`) for a cloud
/// Chief, and a typed error when that brain cannot be reached (2026-10-08:
/// the panel wrote this Mac's engine.json while the server ran claude-sr).
@MainActor @Suite struct HomeChiefSidebarRemoteTests {
    /// A cloud Chief's brain, recorded; `failure` makes every call fail.
    nonisolated final class FakeSource: HomeChiefEngineSource, @unchecked Sendable {
        var snapshot = HomeChiefSnapshot(harness: "codex", model: "gpt-6-sol", effort: nil, avatar: nil, turns: [])
        var failure: HomeChiefEngineError?
        var sets: [(String, String?)] = []
        let isLocal = false
        let place: String? = "cmux-lawrence"

        func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
            if let failure { throw failure }
            return snapshot
        }

        func set(_ key: String, _ value: String?) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
            if let failure { throw failure }
            sets.append((key, value))
            if key == "harness" { snapshot.harness = value }
            return snapshot
        }
    }

    static func views(_ root: NSView) -> [NSView] { root.subviews + root.subviews.flatMap(views) }
    static func visibleTexts(_ root: NSView) -> [String] {
        views(root).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue)
    }
    static func popups(_ root: NSView) -> [NSPopUpButton] { views(root).compactMap { $0 as? NSPopUpButton } }
    static func home() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("chief-sidebar-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func aCloudChiefShowsAndSetsTheServersEngine() async {
        let home = Self.home()
        let source = FakeSource()
        let sidebar = HomeChiefSidebar(muxHome: home)
        await sidebar.use(source).value
        let popups = Self.popups(sidebar)
        #expect(popups.count == 3)
        #expect(popups.allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
        #expect(popups[0].titleOfSelectedItem == "codex", "the server's choice, not this Mac's")
        let texts = Self.visibleTexts(sidebar)
        #expect(texts.contains { $0.contains("cmux-lawrence") }, "\(texts)")
        #expect(!texts.contains { $0.contains(home.path) }, "\(texts)")
        await sidebar.pick("harness", "claude").value
        #expect(source.sets.map(\.0) == ["harness"])
        #expect(source.sets.map(\.1) == ["claude"])
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("optchat/engine.json").path),
                "never this Mac's engine.json")
    }

    @Test func anUnreachableServerIsSaidAndNothingIsPicked() async {
        let source = FakeSource()
        source.failure = .unreachable
        let sidebar = HomeChiefSidebar(muxHome: Self.home())
        await sidebar.use(source).value
        #expect(Self.visibleTexts(sidebar).contains(HomeChiefEngineError.unreachable.text))
        #expect(Self.popups(sidebar).allSatisfy { !$0.isEnabled }, "no pick goes nowhere")
    }

    @Test func aBrainRefusalIsSaidWithItsText() async {
        let source = FakeSource()
        let sidebar = HomeChiefSidebar(muxHome: Self.home())
        await sidebar.use(source).value
        source.failure = .refused(reason: "unknown_harness", message: "acpmux on this host has no harness x")
        await sidebar.pick("harness", "x").value
        #expect(Self.visibleTexts(sidebar).contains { $0.contains("acpmux on this host has no harness x") })
    }

    @Test func theChiefOwnerDaemonStartsWithTheBrainToolsSocket() {
        let root = URL(fileURLWithPath: "/Users/someone/.cmux/chief/default", isDirectory: true)
        let env = ChiefConversationOwner.ownerEnvironment(home: ChiefHome(root: root, isolated: false),
                                                          process: ["HOME": "/Users/someone"])
        #expect(env["CMUX_TUI_CHIEF_TOOLS_SOCKET"] == "/Users/someone/.cmux/chief/default/optchat/tools.sock")
        #expect(env["HOME"] == "/Users/someone")
    }
}
