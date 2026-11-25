@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// A running Cloud machine whose link was refused as not up yet (`parked_timeout`: the relay held the dial its whole
/// deadline and the machine's host never paired) is dialed again by itself. Before cmux#57192 nothing dialed it while
/// its record stayed running, so cloud-chats-11 showed "The machine's connection isn't ready yet (parked_timeout).
/// Click Connect to try again." with its carrier up for 40 minutes.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudNotUpRedialTests {
    /// The link's opens, counted from the resolver's thread.
    private final class Opens: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private static func session(status: CloudMachine.Status, opens: Opens, refusal: CloudLinkError) -> CloudMachineSession {
        let session = CloudTestLink.session(id: "vm-notup-\(UUID().uuidString.prefix(8))", status: status, name: "Parked VM",
                                            opened: { opens.add(); throw refusal })
        // Two quick redials, then the person's Connect (Rust's waits are seconds to minutes).
        session.notUpRedial.delay = { machine, attempt in
            machine.status == .running && attempt < 2 ? .milliseconds(20) : nil
        }
        return session
    }

    /// Waits until `opens` reaches `count`, or a second passes.
    private static func opens(_ opens: Opens, reach count: Int) async -> Int {
        for _ in 0..<100 where opens.value < count { try? await Task.sleep(for: .milliseconds(10)) }
        return opens.value
    }

    @Test func aRunningMachineRefusedAsNotUpIsDialedAgainUntilTheRedialsRunOut() async throws {
        let opens = Opens()
        let session = Self.session(status: .running, opens: opens, refusal: .notUp(state: "parked_timeout"))
        defer { session.disconnect() }
        session.connect()
        #expect(await Self.opens(opens, reach: 3) == 3, "the first dial, then two by itself")
        try await Task.sleep(for: .milliseconds(150))
        #expect(opens.value == 3, "past its redials the machine waits for Connect")
        #expect(session.linkEnded != nil)
        // The person's Connect counts again from the first wait.
        session.retryNow()
        #expect(await Self.opens(opens, reach: 6) == 6)
    }

    @Test func aRefusalThatIsNotNotUpWaitsForAClick() async throws {
        let opens = Opens()
        let session = Self.session(status: .running, opens: opens,
                                   refusal: .helperRefused(code: "handshake", message: "handshake: the Keychain refused the carrier key"))
        defer { session.disconnect() }
        session.connect()
        #expect(await Self.opens(opens, reach: 1) == 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(opens.value == 1)
    }

    @Test func aPauseCancelsTheRedial() async throws {
        let opens = Opens()
        let session = Self.session(status: .running, opens: opens, refusal: .notUp(state: "parked_timeout"))
        defer { session.disconnect() }
        session.notUpRedial.delay = { _, _ in .milliseconds(80) }
        session.connect()
        #expect(await Self.opens(opens, reach: 1) == 1)
        try await Task.sleep(for: .milliseconds(20))
        session.suspend(pausing: true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(opens.value == 1, "a paused machine is not dialed by itself")
    }
}
