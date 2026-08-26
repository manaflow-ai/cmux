import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

/// The diagnostics timeline must state which transport actually carries the
/// foreground connection, both at connect and when the route is swapped
/// mid-connection, so shared reports distinguish Iroh from Tailscale usage
/// without inferring it from surviving dial events.
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
        let iroh = try CmxAttachRoute(
            id: "iroh-route",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: "a", count: 64)
                ),
                pathHints: []
            )
        )

        store.connectionState = .connected
        store.activeRoute = tailscale
        store.activeRoute = iroh

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
            DiagnosticTransportKind.iroh.rawValue,
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

    @Test func transportPathMigrationEventCarriesSessionCorrelation() async throws {
        let log = DiagnosticLog(capacity: 16, role: .mobileClient)
        let store = MobileShellComposite(
            isSignedIn: true,
            diagnosticLog: log
        )

        store.recordTransportPathMigration(
            from: .irohDirect,
            to: .tailscale(address: "100.64.0.42:56_584"),
            sessionID: 91,
            peerID: "test-mac"
        )

        // `c` is the process-local session correlation documented for every
        // transportPathMigration event, including policy-violation migrations.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await log.processedCount() < 1, clock.now < deadline {
            await Task.yield()
        }
        let event = try #require(
            await log.snapshot().events.first(where: {
                $0.code == .transportPathMigration
            })
        )
        #expect(event.diagnosticSessionID == 91)
    }

    @Test func completedPathObservationClearsActiveTransport() async throws {
        let path = CmxTransportPath.tailscale(address: "100.64.0.42:56584")
        let transport = FinitePathObservationTransport(path: path)
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.42", port: 56_584)
        )
        let runtime = LivenessTestRuntime(
            transportFactory: FinitePathObservationTransportFactory(
                transport: transport
            ),
            now: { Date() },
            supportedRouteKinds: [.tailscale]
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            id: "path-observation-install"
        )
        _ = try await client.sendRequest(
            request,
            timeoutNanoseconds: 2_000_000_000
        )

        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected
        )
        store.remoteClient = client
        store.startTransportPathObservation(for: client)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while store.activeTransportPath == .unavailable, clock.now < deadline {
            await Task.yield()
        }
        #expect(store.activeTransportPath == path)

        await transport.finishPathObservation()
        while store.transportPathObservationTask != nil, clock.now < deadline {
            await Task.yield()
        }
        #expect(store.activeTransportPath == .unavailable)
        await client.disconnect()
    }
}

private struct FinitePathObservationTransportFactory: CmxByteTransportFactory {
    let transport: FinitePathObservationTransport

    func makeTransport(for _: CmxAttachRoute) throws -> any CmxByteTransport {
        transport
    }
}

private actor FinitePathObservationTransport: CmxByteTransportPathObserving {
    private let path: CmxTransportPath
    private var queuedFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var pathContinuation: AsyncStream<CmxTransportPath>.Continuation?
    private var isClosed = false

    init(path: CmxTransportPath) {
        self.path = path
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !queuedFrames.isEmpty {
            return queuedFrames.removeFirst()
        }
        if isClosed {
            return nil
        }
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<Data?, Never>) in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        for payload in try MobileSyncFrameCodec.decodeFrames(from: &buffer) {
            guard let request = try JSONSerialization.jsonObject(with: payload)
                    as? [String: Any],
                  let id = request["id"] as? String else {
                continue
            }
            let response: [String: Any] = [
                "id": id,
                "ok": true,
                "result": [:],
            ]
            let responseData = try JSONSerialization.data(withJSONObject: response)
            let frame = try MobileSyncFrameCodec.encodeFrame(responseData)
            if let waiter = receiveWaiters.first {
                receiveWaiters.removeFirst()
                waiter.resume(returning: frame)
            } else {
                queuedFrames.append(frame)
            }
        }
    }

    func close() async {
        isClosed = true
        pathContinuation?.finish()
        pathContinuation = nil
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    func currentTransportPath() async -> CmxTransportPath { path }

    func transportPathChanges() async -> AsyncStream<CmxTransportPath> {
        let (stream, continuation) = AsyncStream<CmxTransportPath>.makeStream()
        pathContinuation = continuation
        continuation.yield(path)
        return stream
    }

    func finishPathObservation() {
        pathContinuation?.finish()
        pathContinuation = nil
    }
}
