import CMUXMobileCore
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

/// Drives every misconfiguration the connection doctor exists for through the
/// pure probe-to-verdict mapping with injected results, and checks that the
/// first failing row in decision-tree order names that misconfiguration with
/// an actionable one-line fix.
@Suite struct ConnectionDoctorReportTests {
    private func tailnetRoute(
        host: String = "100.71.210.41",
        port: Int = 58_465
    ) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "ts", kind: .tailscale, endpoint: .hostPort(host: host, port: port))
    }

    private func loopbackRoute() throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "lo", kind: .debugLoopback, endpoint: .hostPort(host: "127.0.0.1", port: 58_465))
    }

    private func snapshot(
        routes: [CmxAttachRoute],
        isSignedIn: Bool = true,
        lastPairingFailure: MobilePairingFailureCategory? = nil,
        hasActiveUnexpiredTicket: Bool = false
    ) -> ConnectionDoctorProbeResults.ConnectionSnapshot {
        ConnectionDoctorProbeResults.ConnectionSnapshot(
            routes: routes,
            macDeviceID: routes.isEmpty ? nil : "mac-1",
            isSignedIn: isSignedIn,
            accountEmail: "dev@cmux.dev",
            lastPairingFailure: lastPairingFailure,
            hasActiveUnexpiredTicket: hasActiveUnexpiredTicket
        )
    }

    private func dials(
        _ route: CmxAttachRoute,
        _ outcome: ConnectionDoctorProbeResults.DialOutcome
    ) -> [ConnectionDoctorProbeResults.RouteDial] {
        [ConnectionDoctorProbeResults.RouteDial(route: route, outcome: outcome)]
    }

    // MARK: - Report shape

    @Test func reportEmitsEveryCheckInDecisionTreeOrder() throws {
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults())
        #expect(report.items.map(\.id) == ConnectionDoctorItem.CheckID.allCases)
        #expect(report.items.map(\.id) == [
            .network, .localNetwork, .tailnetPhone, .macReachable,
            .account, .listener, .routes, .ticket,
        ])
    }

    @Test func healthySetupHasNoPrimaryFailure() throws {
        let route = try tailnetRoute()
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: true,
            tailscale: .active,
            snapshot: snapshot(routes: [route]),
            dials: dials(route, .accepted),
            registry: .matchesStored
        ))
        #expect(report.primaryFailure == nil)
        for item in report.items {
            #expect(!item.isFailure, "unexpected failure: \(item.id)")
        }
    }

    // MARK: - Network stage

    @Test func offlineDeviceFailsTheNetworkRowFirst() throws {
        let route = try tailnetRoute()
        // Concurrent probes: with no network the dial also fails and the
        // tunnel is down, but the first failing row must still be network.
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: false,
            tailscale: .inactiveOrNotInstalled,
            snapshot: snapshot(routes: [route]),
            dials: dials(route, .unreachable)
        ))
        #expect(report.primaryFailure?.id == .network)
        #expect(report.primaryFailure?.fix?.isEmpty == false)
    }

    @Test func localNetworkDenialFailsThePermissionRow() throws {
        let route = try loopbackRoute()
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: true,
            tailscale: .active,
            snapshot: snapshot(routes: [route]),
            dials: dials(route, .permissionDenied)
        ))
        #expect(report.primaryFailure?.id == .localNetwork)
        #expect(report.primaryFailure?.fix?.contains("Local Network") == true)
        // The reachability row must not double-report the blocked dial as a
        // tailnet problem.
        let reachable = report.items.first { $0.id == .macReachable }
        #expect(reachable?.isFailure == false)
    }

    @Test func lastAttemptLocalNetworkEvidenceCountsWithoutAFreshDial() throws {
        let route = try loopbackRoute()
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: true,
            tailscale: .active,
            snapshot: snapshot(routes: [route], lastPairingFailure: .localNetworkBlocked),
            dials: dials(route, .timedOut)
        ))
        #expect(report.primaryFailure?.id == .localNetwork)
    }

    // MARK: - Tailnet stage

    @Test func tailscaleOffOnPhoneIsTheFirstFailingRowAndNamesTheFix() throws {
        let route = try tailnetRoute()
        // The headline misconfiguration: phone Tailscale off, so the tailnet
        // address is unroutable. The doctor must blame the phone-side switch,
        // not the unreachable Mac.
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: true,
            tailscale: .inactiveOrNotInstalled,
            snapshot: snapshot(routes: [route]),
            dials: dials(route, .unreachable)
        ))
        #expect(report.primaryFailure?.id == .tailnetPhone)
        #expect(report.primaryFailure?.fix?.contains("Tailscale") == true)
    }

    @Test func tailscaleRowIsSkippedWhenNoSavedRouteUsesTheTailnet() throws {
        let route = try loopbackRoute()
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: true,
            tailscale: .inactiveOrNotInstalled,
            snapshot: snapshot(routes: [route]),
            dials: dials(route, .accepted)
        ))
        let row = report.items.first { $0.id == .tailnetPhone }
        guard case .skipped = row?.status else {
            Issue.record("expected skipped tailnet row, got \(String(describing: row?.status))")
            return
        }
        #expect(report.primaryFailure == nil)
    }

    @Test func macUnreachableWithPhoneTailnetUpBlamesTheMacSide() throws {
        let route = try tailnetRoute()
        // Tailscale off on the Mac / different tailnet: phone side is fine,
        // the route is dead.
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: true,
            tailscale: .active,
            snapshot: snapshot(routes: [route]),
            dials: dials(route, .unreachable)
        ))
        #expect(report.primaryFailure?.id == .macReachable)
        #expect(report.primaryFailure?.fix?.contains("tailnet") == true)
    }

    @Test func dialTimeoutReadsAsSleepingMac() throws {
        let route = try tailnetRoute()
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: true,
            tailscale: .active,
            snapshot: snapshot(routes: [route]),
            dials: dials(route, .timedOut)
        ))
        #expect(report.primaryFailure?.id == .macReachable)
        #expect(report.primaryFailure?.fix?.contains("asleep") == true)
    }

    @Test func dnsFailureNamesResolutionAcrossBothDevices() throws {
        let route = try tailnetRoute(host: "my-mac.tail1234.ts.net")
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: true,
            tailscale: .active,
            snapshot: snapshot(routes: [route]),
            dials: dials(route, .dnsFailed)
        ))
        #expect(report.primaryFailure?.id == .macReachable)
        #expect(report.primaryFailure?.fix?.contains("resolve") == true)
    }

    // MARK: - Account stage

    @Test func signedOutDeviceFailsTheAccountRow() throws {
        let route = try tailnetRoute()
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: true,
            tailscale: .active,
            snapshot: snapshot(routes: [route], isSignedIn: false),
            dials: dials(route, .accepted)
        ))
        #expect(report.primaryFailure?.id == .account)
        #expect(report.primaryFailure?.fix?.contains("Sign in") == true)
    }

    @Test func accountMismatchEvidenceFromTheLastAttemptFailsTheAccountRow() throws {
        let route = try tailnetRoute()
        // The Mac rejected the handshake on account grounds: everything below
        // the account row is healthy, so the account row is the diagnosis.
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: true,
            tailscale: .active,
            snapshot: snapshot(routes: [route], lastPairingFailure: .accountMismatch),
            dials: dials(route, .accepted)
        ))
        #expect(report.primaryFailure?.id == .account)
        #expect(report.primaryFailure?.fix?.contains("account") == true)
    }

    @Test func signedInAccountRowShowsTheEmail() throws {
        let route = try tailnetRoute()
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: true,
            tailscale: .active,
            snapshot: snapshot(routes: [route]),
            dials: dials(route, .accepted),
            registry: .matchesStored
        ))
        let account = report.items.first { $0.id == .account }
        guard case let .pass(detail) = account?.status else {
            Issue.record("expected pass, got \(String(describing: account?.status))")
            return
        }
        #expect(detail?.contains("dev@cmux.dev") == true)
    }

    // MARK: - Mac app / listener stage

    @Test func connectionRefusedMeansListenerOffAndMacReachablePasses() throws {
        let route = try tailnetRoute()
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: true,
            tailscale: .active,
            snapshot: snapshot(routes: [route]),
            dials: dials(route, .refused)
        ))
        #expect(report.primaryFailure?.id == .listener)
        #expect(report.primaryFailure?.fix?.contains("cmux") == true)
        let reachable = report.items.first { $0.id == .macReachable }
        guard case .pass = reachable?.status else {
            Issue.record("refused proves routability; got \(String(describing: reachable?.status))")
            return
        }
    }

    @Test func listenerIsUnknownWhileTheMacIsUnreachable() throws {
        let route = try tailnetRoute()
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: true,
            tailscale: .active,
            snapshot: snapshot(routes: [route]),
            dials: dials(route, .unreachable)
        ))
        let listener = report.items.first { $0.id == .listener }
        guard case .unknown = listener?.status else {
            Issue.record("expected unknown listener, got \(String(describing: listener?.status))")
            return
        }
    }

    // MARK: - Routes / ticket stage

    @Test func noSavedRoutesFailsTheRoutesRowAndSkipsTheDialChecks() throws {
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: true,
            tailscale: .active,
            snapshot: snapshot(routes: []),
            dials: []
        ))
        #expect(report.primaryFailure?.id == .routes)
        #expect(report.primaryFailure?.fix?.contains("Pair") == true)
        let reachable = report.items.first { $0.id == .macReachable }
        guard case .skipped = reachable?.status else {
            Issue.record("expected skipped reachability, got \(String(describing: reachable?.status))")
            return
        }
    }

    @Test func registryDisagreementFlagsStaleSavedAddress() throws {
        let route = try tailnetRoute()
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: true,
            tailscale: .active,
            snapshot: snapshot(routes: [route]),
            dials: dials(route, .timedOut),
            registry: .differsFromStored
        ))
        let routes = report.items.first { $0.id == .routes }
        #expect(routes?.isFailure == true)
        #expect(routes?.fix?.contains("address changed") == true)
        // Tree order still points at reachability first; the stale-route row
        // explains why and carries its own fix.
        #expect(report.primaryFailure?.id == .macReachable)
    }

    @Test func expiredTicketEvidenceFailsTheTicketRow() throws {
        let route = try tailnetRoute()
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: true,
            tailscale: .active,
            snapshot: snapshot(routes: [route], lastPairingFailure: .ticketExpired),
            dials: dials(route, .accepted),
            registry: .matchesStored
        ))
        #expect(report.primaryFailure?.id == .ticket)
        #expect(report.primaryFailure?.fix?.contains("expired") == true)
    }

    @Test func unprobedEnvironmentReportsUnknownNotFailure() throws {
        let report = ConnectionDoctorReport.make(results: ConnectionDoctorProbeResults(
            isOnline: nil,
            tailscale: .unknown,
            snapshot: snapshot(routes: []),
            dials: []
        ))
        let network = report.items.first { $0.id == .network }
        guard case .unknown = network?.status else {
            Issue.record("expected unknown network, got \(String(describing: network?.status))")
            return
        }
        let tailnet = report.items.first { $0.id == .tailnetPhone }
        guard case .unknown = tailnet?.status else {
            Issue.record("expected unknown tailnet, got \(String(describing: tailnet?.status))")
            return
        }
    }

    // MARK: - Dial-error classification

    @Test func transportErrorsClassifyOntoDialOutcomes() {
        #expect(ConnectionDoctorProbes.classify(
            dialError: CmxNetworkByteTransportError.connectionFailed("refused", .connectionRefused)
        ) == .refused)
        #expect(ConnectionDoctorProbes.classify(
            dialError: CmxNetworkByteTransportError.connectionFailed("no route", .hostUnreachable)
        ) == .unreachable)
        #expect(ConnectionDoctorProbes.classify(
            dialError: CmxNetworkByteTransportError.connectionTimedOut
        ) == .timedOut)
        #expect(ConnectionDoctorProbes.classify(
            dialError: CmxNetworkByteTransportError.connectionFailed("dns", .dnsFailed)
        ) == .dnsFailed)
        #expect(ConnectionDoctorProbes.classify(
            dialError: CmxNetworkByteTransportError.connectionFailed("denied", .permissionDenied)
        ) == .permissionDenied)
        #expect(ConnectionDoctorProbes.classify(dialError: CancellationError()) == .failed)
    }
}
