import Foundation
import Testing
@testable import CmuxSettings

@MainActor
@Suite("Device discoverability consent", .timeLimit(.minutes(1)))
struct DevicesAccessCoordinatorTests {
    @Test("Cancel does not persist, publish, or change either preference")
    func cancellation() async throws {
        let fixture = Fixture()
        fixture.answer = false
        await fixture.actions.set(true, for: .incomingAccess)
        #expect(fixture.confirmations == 1)
        #expect(fixture.writes.isEmpty)
        #expect(!fixture.value(.incomingAccess))
        #expect(!fixture.value(.discovery))
    }

    @Test("Only a changed incoming enable asks, and the confirmed value survives reopening")
    func confirmedEnable() async throws {
        let fixture = Fixture()
        await fixture.actions.set(true, for: .incomingAccess)
        await fixture.actions.set(true, for: .incomingAccess)
        #expect(fixture.confirmations == 1)
        #expect(fixture.writes == [.init(preference: .incomingAccess, enabled: true)])
        #expect(fixture.value(.incomingAccess))
        #expect(!fixture.value(.discovery))
    }

    @Test("Disabling incoming access never asks for confirmation")
    func disable() async throws {
        let fixture = Fixture()
        fixture.persisted[.incomingAccess] = true
        await fixture.actions.set(false, for: .incomingAccess)
        await fixture.actions.set(false, for: .incomingAccess)
        #expect(fixture.confirmations == 0)
        #expect(fixture.writes == [.init(preference: .incomingAccess, enabled: false)])
        #expect(!fixture.value(.incomingAccess))
    }

    @Test("Peer discovery is immediate and independent", arguments: [false, true])
    func discovery(incomingEnabled: Bool) async throws {
        let fixture = Fixture()
        fixture.persisted[.incomingAccess] = incomingEnabled
        await fixture.actions.set(true, for: .discovery)
        #expect(fixture.value(.discovery))
        await fixture.actions.set(false, for: .discovery)
        #expect(!fixture.value(.discovery))
        #expect(fixture.value(.incomingAccess) == incomingEnabled)
        #expect(fixture.confirmations == 0)
        #expect(fixture.writes.map(\.preference) == [.discovery, .discovery])
    }

    @Test("Concurrent entrypoints cannot repeat a pending enable or publish it early")
    func repeatedRequests() async throws {
        let fixture = Fixture()
        fixture.holdConfirmation = true
        var shown = fixture.confirmationShown.makeAsyncIterator()
        let first = Task { await fixture.actions.set(true, for: .incomingAccess) }
        await shown.next()
        await fixture.actions.set(true, for: .incomingAccess)
        await fixture.actions.set(true, for: .incomingAccess)
        #expect(fixture.confirmations == 1)
        #expect(fixture.writes.isEmpty)
        #expect(!fixture.value(.incomingAccess))
        // Peer discovery remains independent while the privacy decision is pending.
        await fixture.actions.set(true, for: .discovery)
        fixture.reply(true)
        await first.value
        await fixture.actions.set(true, for: .incomingAccess)
        #expect(fixture.confirmations == 1)
        #expect(fixture.writes == [
            .init(preference: .discovery, enabled: true),
            .init(preference: .incomingAccess, enabled: true),
        ])
    }

    @Test("A disable request invalidates an unanswered enable")
    func disableWhileConfirming() async throws {
        let fixture = Fixture()
        fixture.holdConfirmation = true
        var shown = fixture.confirmationShown.makeAsyncIterator()
        let enable = Task { await fixture.actions.set(true, for: .incomingAccess) }
        await shown.next()
        await fixture.actions.set(false, for: .incomingAccess)
        fixture.reply(true)
        await enable.value
        #expect(fixture.writes.isEmpty)
        #expect(!fixture.value(.incomingAccess))
    }

    @Test("Beta unavailability and managed policy reject changes without prompting",
          arguments: [false, true], [DevicesAccessCoordinator.Preference.discovery, .incomingAccess])
    func gated(managed: Bool, preference: DevicesAccessCoordinator.Preference) async throws {
        let fixture = Fixture()
        if managed { fixture.managed.insert(preference) } else { fixture.available = false }
        await fixture.actions.set(true, for: preference)
        #expect(fixture.confirmations == 0)
        #expect(fixture.writes.isEmpty)
    }

    @Test("Policy and availability are checked again after consent", arguments: [false, true])
    func gateChangesWhileConfirming(managed: Bool) async throws {
        let fixture = Fixture()
        fixture.holdConfirmation = true
        var shown = fixture.confirmationShown.makeAsyncIterator()
        let enable = Task { await fixture.actions.set(true, for: .incomingAccess) }
        await shown.next()
        if managed { fixture.managed.insert(.incomingAccess) } else { fixture.available = false }
        fixture.reply(true)
        await enable.value
        #expect(fixture.writes.isEmpty)
        #expect(!fixture.value(.incomingAccess))
    }

    @Test("Cancelling the requesting task cannot enable discoverability")
    func cancelledTask() async throws {
        let fixture = Fixture()
        fixture.holdConfirmation = true
        var shown = fixture.confirmationShown.makeAsyncIterator()
        let enable = Task { await fixture.actions.set(true, for: .incomingAccess) }
        await shown.next()
        enable.cancel()
        fixture.reply(true)
        await enable.value
        #expect(fixture.writes.isEmpty)
    }

    @Test("Disable waits for an in-flight write and remains the final persisted choice")
    func disableDuringWrite() async throws {
        let fixture = Fixture()
        fixture.holdWrite = true
        var started = fixture.writeStarted.makeAsyncIterator()
        let enable = Task { await fixture.actions.set(true, for: .incomingAccess) }
        await started.next()
        let disable = Task { await fixture.actions.set(false, for: .incomingAccess) }
        fixture.finishWrite()
        await enable.value
        await disable.value
        #expect(fixture.confirmations == 1)
        #expect(!fixture.value(.incomingAccess))
        #expect(fixture.writes.map(\.enabled) == [true, false])
    }
}
