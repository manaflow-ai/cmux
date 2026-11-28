@testable import CmuxNextCloud
@testable import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing

/// #65793: after an update the app's first daemon connection dropped while it registered the `credential`
/// family ("not connected to cmux-tui"), the reconnect brought back an equal `.connected`, and nothing registered
/// again, so every Cloud list failed "needs the cmux Mac app connected" until the next reconnect, 27 minutes later.
@MainActor
@Suite struct CloudCredentialRegistrationTests {
    /// The register requests sent, and what each one answers (the last answer repeats).
    actor Sends {
        var answers: [DaemonError?]
        private(set) var count = 0
        init(_ answers: [DaemonError?]) { self.answers = answers }
        func send() throws {
            count += 1
            if let error = answers.count > 1 ? answers.removeFirst() : answers.first ?? nil { throw error }
        }
    }

    @MainActor final class Log {
        var started: [Int] = []
        var cancelled: [Int] = []
    }

    static let quick = Backoff(initial: .milliseconds(1), maximum: .milliseconds(2), jitter: 0)

    @Test func aRegistrationCutByTheDaemonHandoffIsTriedAgain() async {
        let sends = Sends([.notConnected, .connectionClosed(reason: "closed by client"), nil])
        let registered = await CloudCredentialProvider.register(userOriginAllowed: true, backoff: Self.quick) { _ in
            try await sends.send(); return .null
        }
        #expect(registered)
        #expect(await sends.count == 3)
    }

    @Test func theOldConnectionStillHoldingTheFamilyIsTriedAgain() async {
        let taken = DaemonError.command(cmd: "apps-provider-register", message: "another connection already provides credential", code: "apps.provider.taken")
        let sends = Sends([taken, nil])
        let registered = await CloudCredentialProvider.register(userOriginAllowed: true, backoff: Self.quick) { _ in
            try await sends.send(); return .null
        }
        #expect(registered)
        #expect(await sends.count == 2)
    }

    @Test func aRefusalIsNotTriedAgain() async {
        let forbidden = DaemonError.command(cmd: "apps-provider-register", message: "only the verified cmux app connection can provide app ops", code: "apps.provider.forbidden")
        let sends = Sends([forbidden])
        let registered = await CloudCredentialProvider.register(userOriginAllowed: true, backoff: Self.quick) { _ in
            try await sends.send(); return .null
        }
        #expect(!registered)
        #expect(await sends.count == 1)
    }

    @Test func aCancelledRegistrationStopsRetrying() async {
        let sends = Sends([.notConnected])
        let task = Task { @MainActor in
            await CloudCredentialProvider.register(userOriginAllowed: true, backoff: Backoff(initial: .seconds(60), maximum: .seconds(60), jitter: 0)) { _ in
                try await sends.send(); return .null
            }
        }
        while await sends.count == 0 { await Task.yield() }
        task.cancel()
        #expect(await task.value == false)
        #expect(await sends.count == 1)
    }

    /// Each connection epoch registers once: an equal `.connected` on a new epoch (drop and reconnect in between)
    /// starts a new registration and cancels the one in flight; the same epoch observed again starts none.
    @Test func everyConnectedEpochRegistersOnce() async {
        let registration = CloudCredentialRegistration()
        let log = Log()
        func change(_ epoch: Int, connected: Bool) {
            registration.connectionChanged(epoch: epoch, connected: connected) {
                log.started.append(epoch)
                // Hangs like a registration retrying on a connection that is gone, until its epoch ends.
                while !Task.isCancelled { await Task.yield() }
                log.cancelled.append(epoch)
            }
        }
        change(1, connected: true)
        change(1, connected: true)
        while log.started.count < 1 { await Task.yield() }
        change(2, connected: false)
        change(3, connected: true)
        while log.started.count < 2 || log.cancelled.count < 1 { await Task.yield() }
        #expect(log.started == [1, 3])
        #expect(log.cancelled == [1])
        registration.cancel()
        while log.cancelled.count < 2 { await Task.yield() }
        #expect(log.cancelled == [1, 3])
    }

    /// The field failure itself: the first registration fails, the connection drops and comes back with the same
    /// identity (an equal `.connected`), and the store's connection is registered again.
    @Test func aReconnectWithTheSameIdentityRegistersAgain() async throws {
        let store = DaemonStore()
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        let log = Log()
        let following = Task { @MainActor in
            await CloudCredentialRegistration.follow(store) { log.started.append(store.connectionEpoch) }
        }
        defer { following.cancel() }
        store.connectionEpoch += 1
        store.connectionState = .connected(identity)
        while log.started.count < 1 { await Task.yield() }
        // Drop and reconnect in one turn: the loop sees only the equal `.connected`, on a new epoch.
        store.connectionEpoch += 1
        store.connectionState = .disconnected("closed by client")
        store.connectionEpoch += 1
        store.connectionState = .connected(identity)
        while log.started.count < 2 { await Task.yield() }
        #expect(log.started == [1, 3])
    }
}
