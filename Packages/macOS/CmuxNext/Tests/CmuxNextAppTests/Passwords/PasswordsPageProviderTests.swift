@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The Passwords page's provider (plans/cmux-next/passwords.md 1.4 and section 2): metadata-only
/// replies, writes only with the person's gesture, removals and export behind a native sheet,
/// secrets only after device owner authentication and only to the native layer, idempotent
/// retries, and "Available after the next update" for what the build cannot do.
@MainActor @Suite(.serialized) struct PasswordsPageProviderTests {
    struct Fixture {
        let provider: PasswordsPageProvider
        let store: SamplePasswordStore
        let sheet: PasswordSheetFake
        let auth: DeviceOwnerFake
        let surface: SecretSurfaceFake
    }

    let script = PageCallContext(page: "cmux.passwords")
    let person = PageCallContext(page: "cmux.passwords", userGesture: true)

    func make(sheet: Bool = true, auth: Bool = true, store: SamplePasswordStore = SamplePasswordStore()) -> Fixture {
        let sheetFake = PasswordSheetFake(answer: sheet), authFake = DeviceOwnerFake(answer: auth), surface = SecretSurfaceFake()
        let provider = PasswordsPageProvider(
            store: store, profiles: { [.init(id: "default", name: "Default"), .init(id: "work", name: "Work")] },
            confirmations: sheetFake, authenticator: authFake, secrets: surface)
        return Fixture(provider: provider, store: store, sheet: sheetFake, auth: authFake, surface: surface)
    }

    func code(_ body: () async throws -> JSONValue) async -> String? {
        do {
            _ = try await body()
            return nil
        } catch let error as PageError {
            return error.code
        } catch {
            return "other"
        }
    }

    @Test func pageRepliesNeverCarryAPassword() async throws {
        let f = make()
        var replies: [JSONValue] = []
        for op in [PasswordOps.state, PasswordOps.list, PasswordOps.passkeysList, PasswordOps.exceptionsList] {
            replies.append(try await f.provider.call(op, params: ["profile": "default"], context: script))
        }
        replies.append(try await f.provider.call(PasswordOps.reveal, params: ["id": "p1"], context: person))
        replies.append(try await f.provider.call(PasswordOps.copy, params: ["id": "p3"], context: person))
        let text = replies.map(\.compactText).joined()
        for secret in ["sample-pass-1", "123456", "sample-pass-4"] { #expect(!text.contains(secret)) }
        #expect(replies[1]["passwords"]?.arrayValue?.count == 4)
        #expect(replies[4] == ["shown": true])
        #expect(f.surface.revealed.map(\.secret) == ["sample-pass-1"], "only the native sheet got the password")
        #expect(f.surface.copied == ["123456"])
    }

    @Test func scriptWithoutAGestureWritesNothingAndShowsNoSheet() async {
        let f = make()
        let ops: [(String, JSONValue)] = [
            (PasswordOps.remove, ["ids": ["p1"]]), (PasswordOps.usernameSet, ["id": "p1", "username": "x"]),
            (PasswordOps.passkeyRemove, ["id": "cred-1"]), (PasswordOps.exceptionRemove, ["id": "e1"]),
            (PasswordOps.reveal, ["id": "p1"]), (PasswordOps.copy, ["id": "p1"]), (PasswordOps.export, [:]),
        ]
        for (op, params) in ops {
            #expect(await code { try await f.provider.call(op, params: params, context: script) } == PasswordOps.userOnlyCode, "\(op)")
        }
        #expect(f.store.writes.isEmpty)
        #expect(f.sheet.shown.isEmpty && f.auth.reasons.isEmpty && f.surface.revealed.isEmpty && f.surface.copied.isEmpty)
        // Another page id with a gesture is not the Passwords page.
        let other = PageCallContext(page: "cmux.settings", userGesture: true)
        #expect(await code { try await f.provider.call(PasswordOps.copy, params: ["id": "p1"], context: other) } == PasswordOps.userOnlyCode)
    }

    @Test func removalsPassTheNativeSheetAndADeclineChangesNothing() async throws {
        let declined = make(sheet: false)
        #expect(await code { try await declined.provider.call(PasswordOps.remove, params: ["ids": ["p1"]], context: person) } == "cmux.page.cancelled")
        #expect(await code { try await declined.provider.call(PasswordOps.passkeyRemove, params: ["id": "cred-1"], context: person) } == "cmux.page.cancelled")
        #expect(await code { try await declined.provider.call(PasswordOps.exceptionRemove, params: ["id": "e1"], context: person) } == "cmux.page.cancelled")
        #expect(declined.store.writes.isEmpty)
        #expect(declined.sheet.shown.map(\.kind) == [.delete, .delete, .delete])
        #expect(declined.sheet.shown.first?.name == "github.com (octo@example.com)")

        let approved = make()
        let removed = try await approved.provider.call(PasswordOps.remove, params: ["ids": ["p1", "p2"]], context: person)
        #expect(removed["removed"] == 2)
        #expect(approved.sheet.shown.count == 1, "one sheet for one request")
        _ = try await approved.provider.call(PasswordOps.passkeyRemove, params: ["id": "cred-1"], context: person)
        _ = try await approved.provider.call(PasswordOps.exceptionRemove, params: ["id": "e1"], context: person)
        #expect(approved.store.writes == ["remove", "passkey.remove", "exception.remove"])
    }

    @Test func revealAndCopyNeedDeviceOwnerAuthenticationEveryTime() async throws {
        let failed = make(auth: false)
        #expect(await code { try await failed.provider.call(PasswordOps.reveal, params: ["id": "p1"], context: person) } == PasswordOps.authFailedCode)
        #expect(await code { try await failed.provider.call(PasswordOps.copy, params: ["id": "p1"], context: person) } == PasswordOps.authFailedCode)
        #expect(failed.surface.revealed.isEmpty && failed.surface.copied.isEmpty)

        let f = make()
        // A repeated key does not skip authentication: secrets are never replayed.
        _ = try await f.provider.call(PasswordOps.copy, params: ["id": "p1", "idempotency_key": "same"], context: person)
        _ = try await f.provider.call(PasswordOps.copy, params: ["id": "p1", "idempotency_key": "same"], context: person)
        #expect(f.auth.reasons.count == 2)
        #expect(f.auth.reasons.first?.contains("github.com") == true)
        #expect(f.surface.copied.count == 2)
    }

    @Test func aRetriedWriteReplaysWithoutAskingAgain() async throws {
        let f = make()
        let first = try await f.provider.call(PasswordOps.remove, params: ["ids": ["p3"], "idempotency_key": "k1"], context: person)
        let again = try await f.provider.call(PasswordOps.remove, params: ["ids": ["p3"], "idempotency_key": "k1"], context: person)
        #expect(first["removed"] == 1 && first["replayed"] == nil)
        #expect(again["removed"] == 1 && again["replayed"] == true)
        #expect(f.sheet.shown.count == 1 && f.store.writes == ["remove"])
        let opid = PageCallContext(page: "cmux.passwords", opid: "op-1", userGesture: true)
        _ = try await f.provider.call(PasswordOps.usernameSet, params: ["id": "p1", "username": "a"], context: opid)
        _ = try await f.provider.call(PasswordOps.usernameSet, params: ["id": "p1", "username": "b"], context: opid)
        #expect(f.store.savedPasswords["default"]?.first { $0.id == "p1" }?.username == "a", "the opid applied once")
    }

    @Test func exportIsRefusedWhileTheSettingIsOff() async throws {
        let f = make()
        #expect(try await f.provider.call(PasswordOps.state, params: [:], context: script)["export_allowed"] == false)
        #expect(await code { try await f.provider.call(PasswordOps.export, params: [:], context: person) } == PasswordOps.exportOffCode)
        #expect(f.sheet.shown.isEmpty && f.auth.reasons.isEmpty && f.surface.destinationAsks == 0)
        f.provider.exportAllowed = { true }
        #expect(try await f.provider.call(PasswordOps.state, params: [:], context: script)["export_allowed"] == true)
    }

    @Test func exportWarnsThenAuthenticatesThenAsksWhere() async throws {
        let f = make()
        f.provider.exportAllowed = { true }
        var steps: [String] = []
        f.sheet.onShow = { steps.append("sheet") }
        f.auth.onAsk = { steps.append("auth") }
        f.surface.onDestination = { steps.append("where") }
        #expect(await code { try await f.provider.call(PasswordOps.export, params: [:], context: person) } == "cmux.page.cancelled",
                "no destination: nothing is written")
        #expect(steps == ["sheet", "auth", "where"])
        #expect(f.store.writes.isEmpty)

        let file = FileManager.default.temporaryDirectory.appending(path: "pw-export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        f.surface.destination = file
        let reply = try await f.provider.call(PasswordOps.export, params: ["idempotency_key": "e2"], context: person)
        #expect(reply["exported"] == 4)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(reply.compactText.contains("sample-pass") == false)
    }

    @Test func whatTheBuildCannotDoAnswersAvailableAfterTheNextUpdate() async throws {
        let store = SamplePasswordStore()
        store.capabilitiesValue = PasswordStoreCapabilities(passwords: false, passkeys: true, exceptions: false, export: false)
        let f = make(store: store)
        let state = try await f.provider.call(PasswordOps.state, params: [:], context: script)
        #expect(state["sections"] == ["passwords": false, "passkeys": true, "exceptions": false, "export": false])
        do {
            _ = try await f.provider.call(PasswordOps.list, params: [:], context: script)
            Issue.record("listed passwords without the fork API")
        } catch let error as PageError {
            #expect(error.code == PasswordOps.unavailableCode)
            #expect(error.message == PasswordStrings.availableAfterUpdate)
        }
        #expect(await code { try await f.provider.call(PasswordOps.export, params: [:], context: person) } == PasswordOps.unavailableCode)
        #expect(f.sheet.shown.isEmpty, "no sheet for an op the build cannot run")
        #expect(try await f.provider.call(PasswordOps.passkeysList, params: [:], context: script)["passkeys"]?.arrayValue?.count == 1)
    }

    @Test func theChromiumStoreWithoutChromiumOffersNothingButSaysWhy() async {
        let store = ChromiumPasswordStore(engine: { nil })
        #expect(await store.capabilities() == .unsupported)
        await #expect(throws: PasswordStoreError.unavailable) { _ = try await store.passwords(profile: "default") }
        await #expect(throws: PasswordStoreError.unavailable) { _ = try await store.passkeys(profile: "default") }
        await #expect(throws: PasswordStoreError.unavailable) { _ = try await store.password("p1", profile: "default") }
        #expect(await store.counts(profile: "default") == PasswordCounts(passwords: nil, passkeys: nil))
    }

    @Test func unknownProfilesAndMissingRowsAreRefused() async {
        let f = make()
        #expect(await code { try await f.provider.call(PasswordOps.list, params: ["profile": "nope"], context: script) } == "cmux.protocol.invalid_params")
        #expect(await code { try await f.provider.call(PasswordOps.reveal, params: ["id": "zzz"], context: person) } == PasswordOps.notFoundCode)
        #expect(await code { try await f.provider.call(PasswordOps.remove, params: ["ids": []], context: person) } == "cmux.protocol.invalid_params")
        #expect(await code { try await f.provider.call("cmux.passwords.nothing", params: [:], context: script) } == "cmux.protocol.unknown_op")
        #expect(f.auth.reasons.isEmpty)
    }

    @Test func everyStoreChangeSendsOneChangedEvent() async throws {
        let f = make()
        var events: [JSONValue] = []
        let subscription = try await f.provider.subscribe(PasswordOps.changed, filter: [:], context: script) { events.append($0) }
        _ = try await f.provider.call(PasswordOps.usernameSet, params: ["id": "p4", "username": "r"], context: person)
        _ = try await f.provider.call(PasswordOps.exceptionRemove, params: ["id": "e1"], context: person)
        #expect(events.map { $0["profile"] } == ["default", "default"])
        #expect(events.map { $0["revision"] } == [1, 2])
        subscription.cancel()
        _ = try await f.provider.call(PasswordOps.passkeyRemove, params: ["id": "cred-1"], context: person)
        #expect(events.count == 2)
    }

    @Test func thePageIsFirstPartyAndReachesOnlyItsOwnNamespace() {
        let page = PageDescriptor.passwords
        #expect(PageID.isFirstParty(page.id))
        #expect(page.admits(PasswordOps.reveal))
        #expect(!page.admits(PageNativeOp.actionRun) && !page.admits(PageNativeOp.clipboardWrite))
        #expect(!page.admits("cmux.settings.set"))
        #expect(page.actions.isEmpty)
    }
}
