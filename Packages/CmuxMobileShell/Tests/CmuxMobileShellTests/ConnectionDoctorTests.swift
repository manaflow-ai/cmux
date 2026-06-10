import CMUXMobileCore
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

/// Exercises the doctor runner over fully injected probes: the run gathers
/// every probe, dials each host/port route, and publishes one report whose
/// first failing row reflects the injected environment.
@MainActor
@Suite struct ConnectionDoctorTests {
    private func probes(
        routes: [CmxAttachRoute],
        isOnline: Bool? = true,
        tailscale: TailscaleStatus? = .active,
        dialOutcome: ConnectionDoctorProbeResults.DialOutcome = .accepted,
        registry: ConnectionDoctorProbeResults.RegistryCrossCheck = .matchesStored
    ) -> ConnectionDoctorProbes {
        ConnectionDoctorProbes(
            connection: {
                ConnectionDoctorProbeResults.ConnectionSnapshot(
                    routes: routes,
                    macDeviceID: "mac-1",
                    isSignedIn: true,
                    accountEmail: "dev@cmux.dev",
                    lastPairingFailure: nil,
                    hasActiveUnexpiredTicket: false
                )
            },
            isOnline: { isOnline },
            tailscale: { tailscale },
            dial: { _ in dialOutcome },
            registry: { _, _ in registry }
        )
    }

    @Test func runPublishesAReportWithEveryCheck() async throws {
        let route = try CmxAttachRoute(
            id: "ts",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.71.210.41", port: 58_465)
        )
        let doctor = ConnectionDoctor(probes: probes(routes: [route]))
        #expect(doctor.report == nil)
        await doctor.run(trigger: "test")
        let report = try #require(doctor.report)
        #expect(report.items.count == ConnectionDoctorItem.CheckID.allCases.count)
        #expect(report.primaryFailure == nil)
        #expect(doctor.isRunning == false)
    }

    @Test func runDialsEveryHostPortRouteAndSkipsUndialableOnes() async throws {
        let dialed = DialRecorder()
        let hostPort = try CmxAttachRoute(
            id: "ts",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.71.210.41", port: 58_465)
        )
        let loopback = try CmxAttachRoute(
            id: "lo",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58_465)
        )
        let peer = try CmxAttachRoute(
            id: "p2p",
            kind: .iroh,
            endpoint: .peer(id: "peer-1", relayHint: nil, directAddrs: ["1.2.3.4:1"], relayURL: nil)
        )
        var probes = probes(routes: [hostPort, loopback, peer])
        probes.dial = { route in
            await dialed.record(route.id)
            return .accepted
        }
        let doctor = ConnectionDoctor(probes: probes)
        await doctor.run(trigger: "test")
        let ids = await dialed.ids
        #expect(ids.sorted() == ["lo", "ts"])
    }

    @Test func failingEnvironmentSurfacesItsFirstFailingRow() async throws {
        let route = try CmxAttachRoute(
            id: "ts",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.71.210.41", port: 58_465)
        )
        let doctor = ConnectionDoctor(probes: probes(
            routes: [route],
            tailscale: .inactiveOrNotInstalled,
            dialOutcome: .unreachable
        ))
        await doctor.run(trigger: "test")
        #expect(doctor.report?.primaryFailure?.id == .tailnetPhone)
    }

    @Test func aNewerRunSupersedesAnInFlightRun() async throws {
        let route = try CmxAttachRoute(
            id: "ts",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.71.210.41", port: 58_465)
        )
        // First run's dial stalls (a sleeping Mac mid-probe); a re-run with a
        // healthy environment finishes first. Only the newest run may publish,
        // so the stalled run's eventual timeout verdict must be discarded.
        let stallingDial = StallingDial()
        var probes = probes(routes: [route])
        probes.dial = { _ in await stallingDial.dial() }
        let doctor = ConnectionDoctor(probes: probes)
        let firstRun = Task { await doctor.run(trigger: "appear") }
        await stallingDial.waitForFirstDial()
        await doctor.run(trigger: "rerun")
        #expect(doctor.report?.primaryFailure == nil)
        await stallingDial.releaseFirstDial()
        await firstRun.value
        #expect(doctor.report?.primaryFailure == nil)
        #expect(doctor.isRunning == false)
    }
}

/// First dial suspends until released and then reports a timed-out Mac;
/// every later dial succeeds immediately. Pure continuation signalling, so
/// the supersede test is deterministic with no clock.
private actor StallingDial {
    private var dialCount = 0
    private var firstDialStarted = false
    private var firstDialWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func dial() async -> ConnectionDoctorProbeResults.DialOutcome {
        dialCount += 1
        guard dialCount == 1 else { return .accepted }
        firstDialStarted = true
        firstDialWaiters.forEach { $0.resume() }
        firstDialWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return .timedOut
    }

    func waitForFirstDial() async {
        if firstDialStarted { return }
        await withCheckedContinuation { firstDialWaiters.append($0) }
    }

    func releaseFirstDial() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

/// Collects dialed route ids across concurrent probe tasks.
private actor DialRecorder {
    private(set) var ids: [String] = []

    func record(_ id: String) {
        ids.append(id)
    }
}
