@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextWakeups
import Foundation
import Testing

/// A paused Cloud machine stops its `carrier serve`: a child left running kept resuming its relay
/// session on a cached ticket, which never asks the platform, and that traffic woke the VM its person
/// had paused. Only a later connect (a person's resume or attach) starts the serve again.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudPauseStopsCarrierTests {
    @Test func aPauseStopsTheCarrierServeAndAResumeStartsItAgain() async throws {
        let resolver = ServeRecordingResolver()
        let session = CloudMachineSession(machine: CloudMachine(id: "vm-pause", status: .running, displayName: "Paused VM"),
                                          appLink: CloudLinkSession(key: CloudLinkKey(machine: "vm-pause"), resolver: resolver),
                                          localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer { session.disconnect() }
        session.connect()
        try await waitUntil { await resolver.opens >= 1 }
        #expect(await resolver.closes == 0, "a connect leaves the serve running")

        session.suspend()
        try await waitUntil { await resolver.closes >= 1 }
        let opensWhilePaused = await resolver.opens
        try await Task.sleep(for: .milliseconds(200))
        #expect(await resolver.opens == opensWhilePaused, "the paused machine is dialed no more")

        session.connect()
        try await waitUntil { await resolver.opens > opensWhilePaused }
    }

    /// The server took a person's pause: the session parks the link before the paused record arrives.
    @Test func aPauseTheServerTookParksBeforeThePausedRecord() async throws {
        let resolver = ServeRecordingResolver()
        let session = CloudMachineSession(machine: CloudMachine(id: "vm-park", status: .running, displayName: "Parked VM"),
                                          appLink: CloudLinkSession(key: CloudLinkKey(machine: "vm-park"), resolver: resolver),
                                          localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer { session.disconnect() }
        session.connect()
        try await waitUntil { await resolver.opens >= 1 }
        session.suspend(pausing: true)
        try await waitUntil { await resolver.closes >= 1 }
        #expect(session.machine.status == .running, "the record has not said paused yet")
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// The carrier resolver as a recorder: each `open` is a serve dial, each `close` a serve stop.
private actor ServeRecordingResolver: CloudLinkResolver {
    private(set) var opens = 0
    private(set) var closes = 0

    func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        opens += 1
        return CloudLinkSocket(key: key, path: "/tmp/cn-pause-\(key.machine).sock", generation: 1)
    }

    func close(_ key: CloudLinkKey) async { closes += 1 }
}
