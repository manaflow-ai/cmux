import AppKit
@testable import CmuxNextHomeEngine
import Testing

/// Renaming the Chief in Chief Settings sends the daemon's set-title op. A rename the daemon
/// refused (or one with no daemon to send it to) was dropped silently: the field kept the new
/// name over a Chief that kept its old one. It now shows the kept name again and says why.
@MainActor @Suite struct HomeChiefRenameTests {
    static func view() -> HomeChiefSettingsView {
        HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: AnsweringChief())
    }

    @Test func aRefusedRenameShowsTheKeptNameAndSaysSo() async throws {
        let view = Self.view()
        view.onRename = { _ in false }
        view.setName("Chief")
        view.nameField.stringValue = "Ada"
        let rename = try #require(view.commitName())
        await rename.value
        #expect(view.nameField.stringValue == "Chief")
        #expect(!view.failure.isHidden)
        #expect(view.failure.stringValue == HomeEngineStrings.renameRefused)
        // The kept name is no change: leaving the field again sends nothing.
        #expect(view.commitName() == nil)
    }

    /// The Home reads the title again on every transcript or typing change, so the old name
    /// arrives while the rename is on its way: a refusal still says so.
    @Test func aRefusalSaysSoAfterTheOldTitleArrivedAgain() async throws {
        let view = Self.view()
        let (answers, answer) = AsyncStream.makeStream(of: Bool.self)
        view.onRename = { _ in
            for await accepted in answers { return accepted }
            return true
        }
        view.setName("Chief")
        view.nameField.stringValue = "Ada"
        let rename = try #require(view.commitName())
        view.setName("Chief")
        answer.yield(false)
        await rename.value
        #expect(view.nameField.stringValue == "Chief")
        #expect(!view.failure.isHidden)
    }

    @Test func anAcceptedRenameKeepsTheNewName() async throws {
        let view = Self.view()
        var sent: [String] = []
        view.onRename = { sent.append($0); return true }
        view.setName("Chief")
        view.nameField.stringValue = "Ada"
        let rename = try #require(view.commitName())
        await rename.value
        #expect(sent == ["Ada"])
        #expect(view.nameField.stringValue == "Ada")
        #expect(view.failure.isHidden)
    }
}

/// A brain that answers reads.
private struct AnsweringChief: HomeChiefEngineSource {
    var isLocal: Bool { true }
    var place: String? { nil }
    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        HomeChiefSnapshot(harness: nil, model: nil, effort: nil, avatar: nil, turns: [])
    }
    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot { try await read() }
}
