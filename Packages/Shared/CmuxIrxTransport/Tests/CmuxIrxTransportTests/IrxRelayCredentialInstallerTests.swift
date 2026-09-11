import Foundation
import Testing
@testable import CmuxIrxTransport

@Suite(.timeLimit(.minutes(1)))
struct IrxRelayCredentialInstallerTests {
    private func credential(_ token: String, lifetime: TimeInterval = 1800) -> IrxRelayCredential {
        IrxRelayCredential(relayURL: "https://relay.example", token: token,
            expiresAt: Date().addingTimeInterval(lifetime), refreshAfter: Date().addingTimeInterval(1500))
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let reached = try await withIrxDeadline(.seconds(3), onTimeout: {}) {
            while !Task.isCancelled {
                if await condition() { return true }
                try await Task.sleep(for: .milliseconds(5))
            }
            return false
        }
        try #require(reached == true)
    }

    @Test func failedInstallationRetriesTheSameTokenWithoutAnotherRefresh() async throws {
        let native = RelayInstallProbe(failFirst: true)
        let installer = IrxRelayCredentialInstaller(installed: [], journal: IrxLiveTestSupport.journal(),
            sleep: { _ in try await Task.sleep(for: .milliseconds(5)) },
            install: { try await native.install($0) })
        await installer.replace(with: [credential("fresh")])
        try await waitUntil { await native.completed == 1 }
        #expect(await native.tokens == ["fresh", "fresh"])
        #expect(await native.maximumConcurrent == 1)
        await installer.stop()
    }

    @Test func updatesDuringInstallAreSerializedAndOnlyTheLatestPendingTokenRuns() async throws {
        let native = RelayInstallProbe(holdFirst: true)
        let installer = IrxRelayCredentialInstaller(installed: [], journal: IrxLiveTestSupport.journal(),
            install: { try await native.install($0) })
        await installer.replace(with: [credential("first")])
        try await waitUntil { await native.tokens.count == 1 }
        await installer.replace(with: [credential("superseded")])
        await installer.replace(with: [credential("latest")])
        await native.release()
        try await waitUntil { await native.completed == 2 }
        #expect(await native.tokens == ["first", "latest"])
        #expect(await native.maximumConcurrent == 1)
        await installer.stop()
    }

    @Test func newTokenInterruptsBackoffWithoutWaitingForTheOldRetry() async throws {
        let native = RelayInstallProbe(failFirst: true)
        let installer = IrxRelayCredentialInstaller(installed: [], journal: IrxLiveTestSupport.journal(),
            sleep: { _ in
                await native.noteSleep()
                try await Task.sleep(for: .seconds(30))
            }, install: { try await native.install($0) })
        await installer.replace(with: [credential("failed")])
        try await waitUntil { await native.sleepCount == 1 }
        await installer.replace(with: [credential("new")])
        try await waitUntil { await native.completed == 1 }
        #expect(await native.tokens == ["failed", "new"])
        await installer.stop()
    }

    @Test func stoppedInstallerCannotInstallPendingCredentialsAfterAnOldCallReturns() async throws {
        let native = RelayInstallProbe(holdFirst: true)
        let installer = IrxRelayCredentialInstaller(installed: [], journal: IrxLiveTestSupport.journal(),
            install: { try await native.install($0) })
        await installer.replace(with: [credential("in-flight")])
        try await waitUntil { await native.tokens.count == 1 }
        await installer.replace(with: [credential("pending")])
        await installer.stop()
        await installer.replace(with: [credential("after-stop")])
        await native.release()
        try await waitUntil { await native.completed == 1 }
        #expect(await native.tokens == ["in-flight"])
    }

    @Test func alreadyInstalledAndExpiredCredentialsDoNotReachNativeInstallation() async throws {
        let native = RelayInstallProbe()
        let existing = credential("installed")
        let installer = IrxRelayCredentialInstaller(installed: [existing], journal: IrxLiveTestSupport.journal(),
            install: { try await native.install($0) })
        await installer.replace(with: [existing])
        await installer.replace(with: [credential("expired", lifetime: -1)])
        await installer.replace(with: [credential("replacement")])
        try await waitUntil { await native.completed == 1 }
        #expect(await native.tokens == ["replacement"])
        await installer.stop()
    }
}

private actor RelayInstallProbe {
    enum Failure: Error { case unavailable }
    private let failFirst: Bool
    private let holdFirst: Bool
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var concurrent = 0
    private(set) var maximumConcurrent = 0
    private(set) var tokens: [String] = []
    private(set) var completed = 0
    private(set) var sleepCount = 0

    init(failFirst: Bool = false, holdFirst: Bool = false) {
        self.failFirst = failFirst
        self.holdFirst = holdFirst
    }

    func install(_ credential: IrxRelayCredential) async throws {
        tokens.append(credential.token)
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        defer { concurrent -= 1 }
        let first = tokens.count == 1
        if holdFirst, first { await withCheckedContinuation { releaseWaiter = $0 } }
        if failFirst, first { throw Failure.unavailable }
        completed += 1
    }

    func noteSleep() { sleepCount += 1 }
    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
