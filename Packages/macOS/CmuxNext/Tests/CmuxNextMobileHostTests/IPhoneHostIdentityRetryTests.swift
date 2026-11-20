import CmuxNextCompat
import CmuxNextMobile
@testable import CmuxNextMobileHost
import CmuxNextWakeupsTestSupport
import Foundation
import Observation
import Security
import Synchronization
import Testing

/// The iPhone host's wait for a Keychain that refuses this Mac's identity key (2026-11-03: a refused
/// read made a second identity, and the phone that pinned the first was refused until a relaunch).
@MainActor @Suite(.timeLimit(.minutes(1))) struct IPhoneHostIdentityRetryTests {
    @Observable @MainActor final class Toggle {
        var on = true
    }

    /// The reads the host made, and whether each allowed the file store.
    nonisolated final class Reads: Sendable {
        private let state = Mutex<(fileStore: [Bool], refuse: Bool)>(([], true))
        var fileStore: [Bool] { state.withLock { $0.fileStore } }
        func answer() { state.withLock { $0.refuse = false } }
        func read(_ fileStore: Bool) throws -> MobileHostMacIdentity {
            let refuse = state.withLock { state in
                state.fileStore.append(fileStore)
                return state.refuse
            }
            if refuse { throw MobileHostMacIdentityError.keychainRefused(errSecInteractionNotAllowed) }
            throw CancellationError()  // past the identity: this suite starts no hostd
        }
    }

    static func host(reads: Reads, clock: ManualClock, directory: URL) -> IPhoneHostService {
        let host = IPhoneHostService(loginKeychain: LoginKeychain(), pairedStore: MobileHostPairedStore(seal: MobileHostMemoryPairingSeal()))
        host.identityRetryClock = clock
        host.dependencies = .init(executable: URL(fileURLWithPath: "/nonexistent/cmux-mobile-host"),
                                  baseURL: URL(string: "https://mobile.invalid")!, stackProjectID: "test",
                                  stateDirectory: directory, accessToken: { _ in throw CancellationError() },
                                  daemonSocket: { "/nonexistent/daemon.sock" }, acpmux: { nil }, fileRoots: { [] },
                                  computerName: { "Mac" }, macIdentity: { try reads.read($0) })
        return host
    }

    static let account = IPhoneHostService.Account(userID: "user", teamID: "team", teamName: nil, email: nil)

    /// Waits for `condition`, yielding to the host's tasks between reads (bounded by the suite's limit).
    static func until(_ condition: @MainActor () -> Bool) async {
        while !condition() { await Task.yield() }
    }

    /// Refused reads wait on the backoff (1 s doubling to 30 s, 20% jitter), show that the Keychain is locked, and never
    /// use the file store before the DEV fallback's sixth refusal (a Release build never does).
    @Test func aRefusedKeychainWaitsAndReadsAgainWithoutASecondKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reads = Reads(), clock = ManualClock(), toggle = Toggle()
        let host = Self.host(reads: reads, clock: clock, directory: directory)
        defer { host.stop() }
        host.follow(allowed: { toggle.on })
        host.accountChanged(Self.account)
        for (attempt, base) in [1.0, 2, 4, 8, 16, 30].enumerated() {
            try await clock.waitForSleeper()
            #expect(reads.fileStore.count == attempt + 1)
            let wait = try #require(clock.sleeperDeadlines.first).offset - clock.now.offset
            #expect(wait >= .seconds(base * 0.8) && wait <= .seconds(base * 1.2))
            await Self.until { host.phase == .waiting(IPhoneHostStrings.keychainLocked) }
            clock.advance(by: wait)
        }
        await Self.until { reads.fileStore.count == 7 }
        #expect(reads.fileStore.prefix(6).allSatisfy { !$0 })
        #expect(reads.fileStore[6] == IPhoneHostService.mayUseFileStoreOnRefusal)
    }

    /// Turning iPhone connections off during the wait ends it: the host shows off, no retry is left
    /// sleeping, and no read follows (review of #34526: the wait used to swallow the toggle).
    @Test func turningConnectionsOffEndsTheWait() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reads = Reads(), clock = ManualClock(), toggle = Toggle()
        let host = Self.host(reads: reads, clock: clock, directory: directory)
        defer { host.stop() }
        host.follow(allowed: { toggle.on })
        host.accountChanged(Self.account)
        try await clock.waitForSleeper()
        toggle.on = false
        await Self.until { host.phase == .off && clock.sleeperCount == 0 }
        clock.advance(by: .seconds(60))
        for _ in 0..<50 { await Task.yield() }
        #expect(reads.fileStore.count == 1)
    }

    /// The Keychain answering again ends the wait: the next read is the Keychain's, not the file's.
    @Test func theKeychainAnsweringEndsTheWait() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reads = Reads(), clock = ManualClock(), toggle = Toggle()
        let host = Self.host(reads: reads, clock: clock, directory: directory)
        defer { host.stop() }
        host.follow(allowed: { toggle.on })
        host.accountChanged(Self.account)
        try await clock.waitForSleeper()
        reads.answer()
        clock.advance(by: .seconds(2))
        await Self.until { reads.fileStore.count == 2 && clock.sleeperCount == 0 }
        #expect(reads.fileStore == [false, false])
        // The read past the identity reaches hostd's start (this suite's fake stops there): the
        // locked-keychain wait is gone once the supervisor's state stream delivers it.
        await Self.until { host.phase != .waiting(IPhoneHostStrings.keychainLocked) }
    }
}
