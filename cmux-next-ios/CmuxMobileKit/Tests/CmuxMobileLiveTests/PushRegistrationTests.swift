import Foundation
import Testing
@testable import CmuxMobileLive

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PushRegistrationTests {
    private let original = PushRegistration.Preferences(kinds: ["question"], previews: false)
    private let changed = PushRegistration.Preferences(kinds: ["completed"], mutedMacs: ["mac"], previews: true)

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

    private func makeRegistration(_ server: RegistrationServer) -> PushRegistration {
        let registration = PushRegistration(topic: "test.cmux.push", register: { try await server.put($0.preferences) })
        let api = LiveAPI(baseURL: URL(fileURLWithPath: "/unused"), accessToken: { _ in "unused" })
        registration.attach(api: api, deviceID: "phone")
        return registration
    }
}

@MainActor
private final class RegistrationServer {
    var writes: [PushRegistration.Preferences] = []
    var preferences: PushRegistration.Preferences?
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
        if failing { throw URLError(.networkConnectionLost) }
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
