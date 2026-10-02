import CMUXMobileCore
import Foundation
import IrohLib
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohLibEndpointCancellationTests {
    @Test
    func taskCancellationCancelsTheInFlightAttempt() async throws {
        let attempt = ParkedConnectAttempt()
        let fixture = try LibEndpointCancellationFixture(attempt: attempt)
        let dial = Task {
            try await fixture.endpoint.connect(
                to: fixture.address,
                alpn: fixture.alpn
            )
        }

        #expect(await attempt.waitUntilParked())
        dial.cancel()

        let result = await dial.result
        if case let .failure(error) = result {
            #expect(error is CancellationError)
        } else {
            Issue.record("The cancelled dial unexpectedly succeeded")
        }
        #expect(attempt.observedCancelCallCount() >= 1)
    }

    @Test
    func cancelledAttemptMarkerClassifiesToCancelledWithoutTaskCancellation() async throws {
        let fixture = try LibEndpointCancellationFixture(
            attempt: ImmediateCancelledConnectAttempt()
        )

        do {
            _ = try await fixture.endpoint.connect(
                to: fixture.address,
                alpn: fixture.alpn
            )
            Issue.record("The cancelled attempt unexpectedly succeeded")
        } catch {
            #expect(DiagnosticFailureKind.classify(error) == .cancelled)
        }
    }
}

private struct LibEndpointCancellationFixture {
    let endpoint: CmxIrohLibEndpoint
    let address: CmxIrohEndpointAddress
    let alpn: Data

    init(attempt: ConnectAttempt) throws {
        let localIdentity = try CmxIrohLibIdentity.peerIdentity(
            SecretKey.generate().public()
        )
        let remoteIdentity = try CmxIrohLibIdentity.peerIdentity(
            SecretKey.generate().public()
        )
        let configuration = try CmxIrohEndpointConfiguration(
            secretKey: CmxIrohSecretKey(bytes: Data(repeating: 7, count: 32)),
            alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
            managedRelayURLs: [],
            relays: []
        )
        endpoint = CmxIrohLibEndpoint(
            driver: AttemptOnlyEndpoint(attempt: attempt),
            identity: localIdentity,
            configuration: configuration
        )
        address = CmxIrohEndpointAddress(
            identity: remoteIdentity,
            pathHints: []
        )
        alpn = CmxIrohProtocolConfiguration.cmuxMobileV1.alpn
    }
}

// UniFFI requires unchecked sendability; the test message is immutable.
private final class TestIrohError: IrohError, @unchecked Sendable {
    private let testMessage: String

    required init(unsafeFromHandle handle: UInt64) {
        testMessage = ""
        super.init(unsafeFromHandle: handle)
    }

    init(message: String) {
        testMessage = message
        super.init(noHandle: NoHandle())
    }

    override func message() -> String {
        testMessage
    }
}

// UniFFI invokes these synchronous overrides from arbitrary executors; `lock`
// serializes the one parked continuation with cancellation and observations.
private final class ParkedConnectAttempt: ConnectAttempt, @unchecked Sendable {
    private let lock = NSLock()
    private var parkedContinuation: CheckedContinuation<Connection, any Error>?
    private var parked = false
    private var cancelCallCount = 0
    private var cancelled = false

    required init(unsafeFromHandle handle: UInt64) {
        super.init(unsafeFromHandle: handle)
    }

    init() {
        super.init(noHandle: NoHandle())
    }

    override func cancel() {
        let continuation = lock.withLock {
            cancelCallCount += 1
            cancelled = true
            defer { parkedContinuation = nil }
            return parkedContinuation
        }
        continuation?.resume(
            throwing: TestIrohError(
                message: "outgoing connection cancelled"
            )
        )
    }

    override func connect() async throws -> Connection {
        try await withCheckedThrowingContinuation { continuation in
            let shouldCancel = lock.withLock {
                guard !cancelled else { return true }
                parked = true
                parkedContinuation = continuation
                return false
            }
            if shouldCancel {
                continuation.resume(
                    throwing: TestIrohError(
                        message: "outgoing connection cancelled"
                    )
                )
            }
        }
    }

    /// Bounded 1ms-sleep poll: unlike a yield loop, real suspension guarantees
    /// the dial task gets scheduled even when parallel suites saturate the
    /// cooperative pool, while still failing cleanly if the dial never parks.
    func waitUntilParked() async -> Bool {
        for _ in 0 ..< 2_000 {
            if lock.withLock({ parked }) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func observedCancelCallCount() -> Int {
        lock.withLock { cancelCallCount }
    }
}

// UniFFI requires unchecked sendability; `lock` protects the cancel counter.
private final class ImmediateCancelledConnectAttempt:
    ConnectAttempt,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var cancelCallCount = 0

    required init(unsafeFromHandle handle: UInt64) {
        super.init(unsafeFromHandle: handle)
    }

    init() {
        super.init(noHandle: NoHandle())
    }

    override func cancel() {
        lock.withLock {
            cancelCallCount += 1
        }
    }

    override func connect() async throws -> Connection {
        throw TestIrohError(
            message: "outgoing connection cancelled"
        )
    }
}

// UniFFI requires unchecked sendability; the fake endpoint stores one immutable
// attempt and performs no other mutable work.
private final class AttemptOnlyEndpoint: Endpoint, @unchecked Sendable {
    private let testAttempt: ConnectAttempt?

    required init(unsafeFromHandle handle: UInt64) {
        testAttempt = nil
        super.init(unsafeFromHandle: handle)
    }

    init(attempt: ConnectAttempt) {
        testAttempt = attempt
        super.init(noHandle: NoHandle())
    }

    override func beginConnect(
        addr _: EndpointAddr,
        alpn _: Data
    ) throws -> ConnectAttempt {
        guard let testAttempt else {
            throw TestIrohError(message: "missing test attempt")
        }
        return testAttempt
    }

    override func connect(
        addr _: EndpointAddr,
        alpn _: Data
    ) async throws -> Connection {
        throw TestIrohError(
            message: "plain Endpoint.connect must not be used; dial must go through beginConnect"
        )
    }
}
