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

    /// Lawrence 2026-11-07, "renaming chief doesnt work": he renamed the Chief to "Chief mom" and
    /// it saved (registry rev 4), then the card sent "Chief" 1.9 s later (rev 5, the same
    /// `home-chief-rename-agent_mux-*` path). The field still showed "Chief" while he was in it,
    /// the Home moved the name to "Chief mom" meanwhile (only `shownName`, since the field was
    /// being edited), and leaving the field sent the text he never touched. Leaving a field the
    /// person did not change renames nothing and shows the newest name.
    @Test func leavingAnUntouchedFieldNeverPutsBackTheOldName() throws {
        let view = Self.view()
        var sent: [String] = []
        view.onRename = { sent.append($0); return nil }
        view.setName("Chief")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(view)
        try #require(window.makeFirstResponder(view.nameField))
        #expect(view.nameField.currentEditor() != nil)
        // The rename saved meanwhile (its echo, or the CLI, the phone, Settings > Chief).
        view.setName("Chief mom")
        #expect(view.nameField.stringValue == "Chief")
        // Leaving the field (a click elsewhere, the card closing) sends its action.
        #expect(view.commitName() == nil)
        #expect(sent.isEmpty)
        #expect(view.nameField.stringValue == "Chief mom")
        // The real end of editing (sendsActionOnEndEditing) sends nothing either.
        try #require(window.makeFirstResponder(view.nameField))
        window.makeFirstResponder(nil)
        #expect(sent.isEmpty)
        #expect(view.nameField.stringValue == "Chief mom")
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
