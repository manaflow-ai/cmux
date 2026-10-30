import AppKit
import CmuxNextDaemon
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

    /// Issue 27915: the owner saved "MARIO" but its answer was lost, so the card said "could not
    /// be changed" and put "Chief" back in the field, still being edited. The saved record's
    /// echo then named the Chief "MARIO", and leaving the field sent "Chief" as a new rename:
    /// the person's saved name was undone 3 s later (the registry's history on the reporter's
    /// Mac). A name the card put back itself is no rename.
    @Test func leavingTheFieldAfterARefusalRenamesNothing() async throws {
        let view = Self.view()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: HomeChiefSettingsView.width, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        var sent: [String] = []
        view.onRename = { name in
            sent.append(name)
            return sent.count == 1 ? .noConnection : nil
        }
        view.setName("Chief")
        #expect(window.makeFirstResponder(view.nameField))
        view.nameField.stringValue = "MARIO"
        await try #require(view.commitName()).value
        // Still in the field (Return keeps the editor), it shows the kept name.
        #expect(view.nameField.currentEditor() != nil)
        #expect(view.nameField.stringValue == "Chief")
        // The saved record's echo arrives: the Chief is named MARIO after all.
        view.setName("MARIO")
        // Leaving the field: the card's own "Chief" is not the person's.
        let leave = view.commitName()
        await leave?.value
        #expect(leave == nil)
        #expect(sent == ["MARIO"])
    }

    /// A name the person types after a refusal still renames.
    @Test func typingAgainAfterARefusalRenames() async throws {
        let view = Self.view()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: HomeChiefSettingsView.width, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        var sent: [String] = []
        view.onRename = { name in
            sent.append(name)
            return sent.count == 1 ? .noConnection : nil
        }
        view.setName("Chief")
        #expect(window.makeFirstResponder(view.nameField))
        view.nameField.stringValue = "MARIO"
        await try #require(view.commitName()).value
        view.nameField.stringValue = "Luigi"
        await try #require(view.commitName()).value
        #expect(sent == ["MARIO", "Luigi"])
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

/// Issue 27915: a rename of this Mac's Chief whose answer is lost (the connection closed, timed
/// out, or answered what could not be read) may have been saved. It asks once more with the same
/// idempotency key, so the owner answers the save it made; only a second loss says "try again".
@Suite struct HomeLocalChiefRenameRetryTests {
    actor Calls {
        var keys: [String] = []
        func add(_ key: String) -> Int {
            keys.append(key)
            return keys.count
        }
    }

    @Test(arguments: [DaemonError.connectionClosed(reason: "eof"), .timedOut("chief.profile.update"),
                      .malformedResponse("JSONValue"), .notConnected])
    func aLostAnswerIsAskedAgainWithTheSameKey(_ lost: DaemonError) async {
        let calls = Calls()
        let failure = await HomeLocalChiefRename(chief: "agent_mux", name: "MARIO").send { key in
            if await calls.add(key) == 1 { throw lost }
        }
        #expect(failure == nil)
        let keys = await calls.keys
        #expect(keys.count == 2)
        #expect(Set(keys).count == 1)
        #expect(keys.first?.hasPrefix("home-chief-rename-agent_mux-") == true)
    }

    @Test func twoLostAnswersSayTryAgain() async {
        let calls = Calls()
        let failure = await HomeLocalChiefRename(chief: "agent_mux", name: "MARIO").send { key in
            _ = await calls.add(key)
            throw DaemonError.connectionClosed(reason: "eof")
        }
        #expect(failure == .noConnection)
        #expect(await calls.keys.count == 2)
    }

    @Test func aRefusalIsNotAskedAgain() async {
        let calls = Calls()
        let failure = await HomeLocalChiefRename(chief: "agent_mux", name: "").send { key in
            _ = await calls.add(key)
            throw DaemonError.command(cmd: "chief.profile.update", message: "display_name", code: "validation.invalid")
        }
        #expect(failure == .invalidName)
        #expect(await calls.keys.count == 1)
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
