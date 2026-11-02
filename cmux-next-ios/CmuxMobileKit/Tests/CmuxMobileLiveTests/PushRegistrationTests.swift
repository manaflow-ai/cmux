import Foundation
import Testing
@testable import CmuxMobileLive

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PushRegistrationTests {
    private let original = PushRegistration.Preferences(kinds: ["question"], previews: false)
    private let changed = PushRegistration.Preferences(kinds: ["completed"], mutedMacs: ["mac"], previews: true)

    /// On a cold background notification reply, PushReplies creates a headless
    /// LiveCoordinator before any ShellView exists. The APNs token and API
    /// can arrive, but a PUT must never replace the Worker's saved prefs with
    /// the app's hard-coded default notification kinds and previews-on.
    @Test func headlessAttachWithoutPreferencesLeavesServerChoicesUntouched() async {
        let server = RegistrationServer()
        server.preferences = original // Worker row persisted from an earlier launch
        let registration = makeRegistration(server)
        registration.didRegister(deviceToken: Data([1, 2]))
        #expect(registration.task == nil)
        #expect(server.writes.isEmpty)
        #expect(server.preferences == original)
        #expect(!registration.receivesChiefPushes)

        // Foreground ShellView has now published the actual user's choices.
        registration.setPreferences(changed)
        await registration.task?.value
        #expect(server.writes == [changed])
        #expect(server.preferences == changed)
    }

    /// A sign-out clears the source of preferences too: a quick second
    /// account may have a cached APNs token, but it still waits for its own
    /// foreground preferences before publishing a new row.
    @Test func signOutDoesNotCarryThePreviousAccountsPreferencesIntoNextAttach() async {
        let server = RegistrationServer()
        let registration = makeRegistration(server)
        registration.setPreferences(original)
        registration.didRegister(deviceToken: Data([1, 2]))
        await registration.task?.value
        await registration.unregister()

        let api = LiveAPI(baseURL: URL(fileURLWithPath: "/unused"), accessToken: { _ in "unused" })
        registration.attach(api: api, deviceID: "phone")
        #expect(registration.task == nil)
        #expect(server.preferences == nil)

        registration.setPreferences(changed)
        await registration.task?.value
        #expect(server.events == ["put", "delete", "put"])
        #expect(server.preferences == changed)
    }

    /// Chief's local alerts stand down only once the service has accepted a
    /// registration that includes `chief` (duplicate Chief notifications, 2026-10-30).
    @Test func receivesChiefPushesOnlyAfterAcceptedChiefRegistration() async {
        let server = RegistrationServer()
        let registration = makeRegistration(server)
        registration.setPreferences(.init(kinds: ["question", "chief"]))
        #expect(!registration.receivesChiefPushes)
        registration.didRegister(deviceToken: Data([1, 2]))
        await registration.task?.value
        #expect(registration.receivesChiefPushes)

        registration.setPreferences(.init(kinds: ["question"]))
        await registration.task?.value
        #expect(!registration.receivesChiefPushes)

        registration.setPreferences(.init(kinds: ["chief"]))
        await registration.task?.value
        #expect(registration.receivesChiefPushes)
        await registration.unregister()
        #expect(!registration.receivesChiefPushes)
    }

    @Test func restoringAcceptedPreferencesWhileWriteIsPendingRestoresServer() async {
        let server = RegistrationServer()
        let registration = makeRegistration(server)
        registration.setPreferences(original)
        registration.didRegister(deviceToken: Data([1, 2]))
        await registration.task?.value
        #expect(server.preferences == original)

        server.holdNext = true
        registration.setPreferences(changed)
        await server.waitUntilHeld()
        let pending = registration.task
        registration.setPreferences(original)
        server.release()
        await pending?.value

        #expect(server.writes == [original, changed, original])
        #expect(server.preferences == original)
    }

    @Test func rapidChangesCoalesceBehindOutstandingWrite() async {
        let server = RegistrationServer()
        let registration = makeRegistration(server)
        registration.setPreferences(original)
        registration.didRegister(deviceToken: Data([1, 2]))
        await registration.task?.value

        server.holdNext = true
        registration.setPreferences(changed)
        await server.waitUntilHeld()
        let pending = registration.task
        registration.setPreferences(.init(kinds: ["failed"]))
        registration.setPreferences(original)
        #expect(server.writes == [original, changed])
        server.release()
        await pending?.value

        #expect(server.writes == [original, changed, original])
        #expect(server.preferences == original)
    }

    @Test func failedWriteStillReconcilesNewerPreferences() async {
        let server = RegistrationServer()
        let registration = makeRegistration(server)
        registration.setPreferences(original)
        registration.didRegister(deviceToken: Data([1, 2]))
        await registration.task?.value

        server.holdNext = true
        registration.setPreferences(changed)
        await server.waitUntilHeld()
        let pending = registration.task
        registration.setPreferences(original)
        // The server applied the mutation but its response was lost.
        server.release(failing: true)
        await pending?.value

        #expect(server.writes == [original, changed, original])
        #expect(server.preferences == original)
    }

    @Test func repeatedAcceptedPreferencesDoNotWriteAgain() async {
        let server = RegistrationServer()
        let registration = makeRegistration(server)
        registration.setPreferences(original)
        registration.didRegister(deviceToken: Data([1, 2]))
        await registration.task?.value
        registration.setPreferences(original)
        await registration.task?.value
        #expect(server.writes == [original])
    }

    /// Registration is stored by the Worker across launches; a fresh process
    /// has no APNs token or successful PUT in its local `sent` cache.
    @Test func signOutDeletesPreviousLaunchRegistrationWithoutCurrentToken() async {
        let server = RegistrationServer()
        server.preferences = original
        let registration = makeRegistration(server)

        await registration.unregister()

        #expect(server.deletions == 1)
        #expect(server.preferences == nil)
        #expect(server.writes.isEmpty)
    }

    /// A lost PUT response means local `sent` stays nil even though the Worker
    /// accepted the token. Sign-out must still remove it.
    @Test func signOutDeletesRegistrationAfterLostPutResponse() async {
        let server = RegistrationServer()
        let registration = makeRegistration(server)
        server.holdNext = true
        registration.setPreferences(original)
        registration.didRegister(deviceToken: Data([1, 2]))
        await server.waitUntilHeld()
        let put = registration.task
        server.release(failing: true)
        await put?.value
        #expect(server.preferences == original)

        await registration.unregister()

        #expect(server.deletions == 1)
        #expect(server.preferences == nil)
        #expect(server.events == ["put", "delete"])
    }

    /// Sign-out drains the last PUT before DELETE; a delayed registration must
    /// never repopulate a signed-out phone's server row.
    @Test func signOutDeletesAfterAnOutstandingPut() async {
        let server = RegistrationServer()
        let registration = makeRegistration(server)
        server.holdNext = true
        registration.setPreferences(original)
        registration.didRegister(deviceToken: Data([1, 2]))
        await server.waitUntilHeld()

        let signOut = Task { await registration.unregister() }
        server.release()
        await signOut.value

        #expect(server.deletions == 1)
        #expect(server.preferences == nil)
        #expect(server.events == ["put", "delete"])
    }

    /// A quick sign-in reattaches the same device id while sign-out still
    /// waits on the old PUT. The old DELETE runs first, then the new PUT, so
    /// the re-signed-in phone keeps its registration.
    @Test func aQuickSignInRegistersAfterTheSignOutDelete() async {
        let server = RegistrationServer()
        let registration = makeRegistration(server)
        server.holdNext = true
        registration.setPreferences(original)
        registration.didRegister(deviceToken: Data([1, 2]))
        await server.waitUntilHeld()

        let signOut = Task { await registration.unregister() }
        while registration.task != nil { await Task.yield() }
        let api = LiveAPI(baseURL: URL(fileURLWithPath: "/unused"), accessToken: { _ in "unused" })
        registration.attach(api: api, deviceID: "phone")
        // The new account's Settings owner restores these choices explicitly.
        registration.setPreferences(original)
        let signIn = registration.task
        server.release()
        await signOut.value
        await signIn?.value

        #expect(server.events == ["put", "delete", "put"])
        #expect(server.preferences == original)
    }

    /// A writer created but not yet started when sign-out begins must not wait
    /// on the cleanup that waits on it.
    @Test func signOutRightAfterAQueuedWriteDoesNotDeadlock() async {
        let server = RegistrationServer()
        let registration = makeRegistration(server)
        registration.setPreferences(original)
        registration.didRegister(deviceToken: Data([1, 2]))
        #expect(registration.task != nil)

        await registration.unregister()

        #expect(server.events == ["delete"])
        #expect(server.preferences == nil)
    }

    /// The sign-out hook is bounded and cancels its caller; the DELETE still runs.
    @Test func aCancelledSignOutStillDeletes() async {
        let server = RegistrationServer()
        let registration = makeRegistration(server)
        server.holdNext = true
        registration.setPreferences(original)
        registration.didRegister(deviceToken: Data([1, 2]))
        await server.waitUntilHeld()

        let signOut = Task { await registration.unregister() }
        while registration.task != nil { await Task.yield() }
        signOut.cancel()
        server.release()
        await signOut.value
        await registration.cleanup?.value

        #expect(server.events == ["put", "delete"])
        #expect(server.preferences == nil)
    }

    /// The pinned bearer keeps `call`'s 401 recovery: a refresh asks the provider.
    @Test func aPinnedBearerStillRefreshesAfterA401() async throws {
        let calls = RefreshCalls()
        let api = LiveAPI(baseURL: URL(fileURLWithPath: "/unused"), accessToken: { force in
            await calls.record(force)
            return force ? "fresh" : "cached"
        })
        let pinned = try await api.pinningToken()
        #expect(try await pinned.accessToken(false) == "cached")
        #expect(try await pinned.accessToken(true) == "fresh")
        #expect(await calls.seen == [false, true])
    }

    private func makeRegistration(_ server: RegistrationServer) -> PushRegistration {
        let registration = PushRegistration(topic: "test.cmux.push",
                                            register: { try await server.put($0.preferences) },
                                            delete: { _, _ in server.delete() })
        let api = LiveAPI(baseURL: URL(fileURLWithPath: "/unused"), accessToken: { _ in "unused" })
        registration.attach(api: api, deviceID: "phone")
        return registration
    }
}

private actor RefreshCalls {
    private(set) var seen: [Bool] = []
    func record(_ force: Bool) { seen.append(force) }
}

@MainActor
private final class RegistrationServer {
    var writes: [PushRegistration.Preferences] = []
    var preferences: PushRegistration.Preferences?
    private(set) var deletions = 0
    private(set) var events: [String] = []
    var holdNext = false
    private var held: CheckedContinuation<Bool, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func put(_ preferences: PushRegistration.Preferences) async throws {
        writes.append(preferences)
        var failing = false
        if holdNext {
            holdNext = false
            failing = await withCheckedContinuation { continuation in
                held = continuation
                started?.resume()
                started = nil
            }
        }
        self.preferences = preferences
        events.append("put")
        if failing { throw URLError(.networkConnectionLost) }
    }

    func delete() {
        deletions += 1
        preferences = nil
        events.append("delete")
    }

    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release(failing: Bool = false) {
        held?.resume(returning: failing)
        held = nil
    }
}
