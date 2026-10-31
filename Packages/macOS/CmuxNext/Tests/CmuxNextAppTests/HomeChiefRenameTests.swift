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
        view.onRename = { _ in .noConnection }
        view.setName("Chief")
        view.nameField.stringValue = "Ada"
        let rename = try #require(view.commitName())
        await rename.value
        #expect(view.nameField.stringValue == "Chief")
        #expect(!view.failure.isHidden)
        #expect(view.failure.stringValue == HomeEngineStrings.renameFailed(.noConnection))
        // The kept name is no change: leaving the field again sends nothing.
        #expect(view.commitName() == nil)
    }

    /// The Home reads the title again on every transcript or typing change, so the old name
    /// arrives while the rename is on its way: a refusal still says so.
    @Test func aRefusalSaysSoAfterTheOldTitleArrivedAgain() async throws {
        let view = Self.view()
        let (answers, answer) = AsyncStream.makeStream(of: HomeChiefRenameFailure?.self)
        view.onRename = { _ in
            for await failure in answers { return failure }
            return nil
        }
        view.setName("Chief")
        view.nameField.stringValue = "Ada"
        let rename = try #require(view.commitName())
        view.setName("Chief")
        answer.yield(.noConnection)
        await rename.value
        #expect(view.nameField.stringValue == "Chief")
        #expect(!view.failure.isHidden)
    }

    @Test func anAcceptedRenameKeepsTheNewName() async throws {
        let view = Self.view()
        var sent: [String] = []
        view.onRename = { sent.append($0); return nil }
        view.setName("Chief")
        view.nameField.stringValue = "Ada"
        let rename = try #require(view.commitName())
        await rename.value
        #expect(sent == ["Ada"])
        #expect(view.nameField.stringValue == "Ada")
        #expect(view.failure.isHidden)
    }

    /// The card says why a rename failed (Lawrence 2026-10-21: a cloud Chief's rename only said
    /// "Try again in a moment", which no retry fixed).
    @Test(arguments: [HomeChiefRenameFailure.signedOut, .changedElsewhere, .invalidName, .notFound, .refused("chief_archived")])
    func aFailureNamesItsReason(_ reason: HomeChiefRenameFailure) async throws {
        let view = Self.view()
        view.onRename = { _ in reason }
        view.setName("Chief")
        view.nameField.stringValue = "Ada"
        let rename = try #require(view.commitName())
        await rename.value
        #expect(view.failure.stringValue == HomeEngineStrings.renameFailed(reason))
        #expect(view.failure.stringValue != HomeEngineStrings.renameFailed(.noConnection))
    }

    /// The avatar's "Change Picture" tooltip opens below the avatar, over the note: it steps aside
    /// while a note shows and comes back once the note is gone.
    @Test func theAvatarTooltipNeverCoversTheNote() async throws {
        let view = Self.view()
        #expect(view.avatarButton.themedToolTip == HomeEngineStrings.changePicture)
        view.onRename = { _ in .noConnection }
        view.setName("Chief")
        view.nameField.stringValue = "Ada"
        await try #require(view.commitName()).value
        #expect(!view.failure.isHidden)
        #expect(view.avatarButton.themedToolTip == nil)
        #expect(view.avatarButton.accessibilityLabel() == HomeEngineStrings.changePicture)
        view.onRename = { _ in nil }
        view.nameField.stringValue = "Bea"
        await try #require(view.commitName()).value
        #expect(view.failure.isHidden)
        #expect(view.avatarButton.themedToolTip == HomeEngineStrings.changePicture)
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
