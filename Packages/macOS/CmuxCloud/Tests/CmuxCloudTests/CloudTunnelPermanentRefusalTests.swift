@testable import CmuxCloud
import Foundation
import Testing

/// Production, 2026-09-29: after a Mac's Cloud access grant was revoked, the
/// WireGuard hub's startup recovery sent `POST /api/vm/tunnel` four times per
/// start (1 s, 2 s, 4 s apart), and every caller restarted it. The server's
/// `403 vm_access_revoked` is not retryable; only a new sign-in can fix it.
@Suite("Cloud tunnel permanent refusal")
struct CloudTunnelPermanentRefusalTests {
    /// The exact body `web/services/vms/routeHelpers.ts` sends.
    static let revokedBody = #"""
    {"phase":"network","retryable":false,"ui":{"title":"Cloud VM authentication required","message":"Cloud access for this Mac login was revoked.","phase":"network","severity":"error","retryable":false,"traceId":"0af7651916cd43dd8448eb211c80319c"},"error":"vm_access_revoked","message":"Cloud access for this Mac login was revoked.","reason":"Cloud access for this Mac login was revoked.","action":"Sign out of cmux, then sign in again to enroll this Mac.","traceId":"0af7651916cd43dd8448eb211c80319c"}
    """#

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    actor SleepLog {
        private(set) var durations: [Duration] = []
        func record(_ duration: Duration) { durations.append(duration) }
    }

    final class NeverSpawner: CloudWireGuardHubSpawning, @unchecked Sendable {
        func spawn(executable: URL, arguments: [String]) throws -> any CloudWireGuardHubProcess {
            throw CancellationError()
        }
    }

    private func makeHub(
        enrollError: VMClientError,
        enrolls: Counter,
        sleeps: SleepLog
    ) -> CloudWireGuardHub {
        CloudWireGuardHub(configuration: .init(
            enroll: {
                enrolls.increment()
                throw enrollError
            },
            clientURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketURL: URL(fileURLWithPath: "/tmp/permanent-refusal-hub.sock"),
            spawner: NeverSpawner(),
            waitUntilReady: { _ in },
            sleep: { duration in await sleeps.record(duration) },
            restartBackoff: CloudWireGuardHub.Configuration.defaultRestartBackoff,
            idleGrace: .seconds(3600)
        ))
    }

    @Test("A revoked login enrolls once per start, with no recovery sleeps")
    func revokedLoginDoesNotRetryInsideStartup() async {
        let enrolls = Counter()
        let sleeps = SleepLog()
        let hub = makeHub(enrollError: .httpStatus(403, Self.revokedBody), enrolls: enrolls, sleeps: sleeps)
        await #expect(throws: VMClientError.self) { _ = try await hub.acquire() }
        #expect(enrolls.count == 1)
        #expect(await sleeps.durations.isEmpty)
    }

    @Test("A transient enrollment failure keeps the bounded startup recovery")
    func transientFailureKeepsRecovery() async {
        let enrolls = Counter()
        let sleeps = SleepLog()
        let body = #"{"error":"vm_tunnel_enrollment_unavailable","retryable":true,"retryAfterSeconds":30}"#
        let hub = makeHub(enrollError: .httpStatus(503, body), enrolls: enrolls, sleeps: sleeps)
        await #expect(throws: VMClientError.self) { _ = try await hub.acquire() }
        #expect(enrolls.count == 4)
        #expect(await sleeps.durations == [.seconds(1), .seconds(2), .seconds(4)])
    }

    @Test("VMClientError names a permanent tunnel refusal")
    func errorClassification() {
        #expect(VMClientError.httpStatus(403, Self.revokedBody).isPermanentCloudTunnelRefusal)
        #expect(VMClientError.httpStatus(403, Self.revokedBody).isCloudAccessRevoked)
        #expect(!VMClientError.httpStatus(503, "{}").isPermanentCloudTunnelRefusal)
        #expect(!VMClientError.backendUnreachable(url: "https://cmux.com", detail: "offline").isPermanentCloudTunnelRefusal)
        #expect(!VMClientError.notSignedIn.isCloudAccessRevoked)
    }

    @Test("The revoked refusal reads as a sign-in action, not a retry")
    func revokedDescriptionLeadsToSignIn() {
        let text = VMClientError.httpStatus(403, Self.revokedBody).description
        #expect(text.contains("Cloud access for this Mac was revoked"))
        #expect(text.contains("Sign out of cmux, then sign in again"))
        #expect(text.contains("vm_access_revoked"))
        #expect(text.contains("0af7651916cd43dd8448eb211c80319c"))
        #expect(!text.contains("Retrying is safe"))
        #expect(!text.contains("Cloud VM authentication required"))
    }
}
