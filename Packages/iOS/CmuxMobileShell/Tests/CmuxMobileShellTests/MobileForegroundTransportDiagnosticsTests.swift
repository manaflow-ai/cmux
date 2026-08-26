import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

/// The diagnostics timeline must state which transport actually carries the
/// foreground connection, both at connect and when the route is swapped
/// mid-connection, so shared reports name the transport without inferring it
/// from surviving dial events.
@MainActor
@Suite struct MobileForegroundTransportDiagnosticsTests {
    @Test func connectAndRouteChangeRecordSelectedTransport() async throws {
        let log = DiagnosticLog(capacity: 16, role: .mobileClient)
        let store = MobileShellComposite(
            isSignedIn: true,
            diagnosticLog: log
        )
        let tailscale = try CmxAttachRoute(
            id: "granted-tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.42", port: 56_584)
        )
        let loopback = try CmxAttachRoute(
            id: "loopback-route",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_585)
        )

        store.connectionState = .connected
        store.activeRoute = tailscale
        store.activeRoute = loopback

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        func selectedTransports() async -> [Int] {
            await log.snapshot().events
                .filter {
                    $0.code == .appFeatureAction && $0.a
                        == DiagnosticAppEventKind.foregroundTransportSelected.rawValue
                }
                .compactMap(\.c)
        }
        while await selectedTransports().count < 2, clock.now < deadline {
            await Task.yield()
        }
        #expect(await selectedTransports() == [
            DiagnosticTransportKind.tailscale.rawValue,
            DiagnosticTransportKind.debugLoopback.rawValue,
        ])
    }

    @Test func disconnectedRouteChangesRecordNothing() async throws {
        let log = DiagnosticLog(capacity: 16, role: .mobileClient)
        let store = MobileShellComposite(
            isSignedIn: true,
            diagnosticLog: log
        )
        let tailscale = try CmxAttachRoute(
            id: "granted-tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.42", port: 56_584)
        )

        store.activeRoute = tailscale

        // A directly recorded sentinel bounds the drain wait: once it has been
        // processed, any transport event recorded before it would be visible.
        log.recordAppEvent(.appLaunched)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await log.processedCount() < 1, clock.now < deadline {
            await Task.yield()
        }
        let selected = await log.snapshot().events.filter {
            $0.code == .appFeatureAction && $0.a
                == DiagnosticAppEventKind.foregroundTransportSelected.rawValue
        }
        #expect(selected.isEmpty)
    }
}
