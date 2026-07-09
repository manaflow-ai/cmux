import CMUXMobileCore
import Foundation

final class RouteAttemptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [CmxAttachTransportKind: Int] = [:]

    func record(_ kind: CmxAttachTransportKind) {
        lock.withLock { counts[kind, default: 0] += 1 }
    }

    func count(_ kind: CmxAttachTransportKind) -> Int {
        lock.withLock { counts[kind, default: 0] }
    }
}

struct ManualFallbackApprovalTransportFactory: CmxByteTransportFactory {
    let router: LivenessHostRouter
    let box: TransportBox
    var attempts: RouteAttemptRecorder?

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        attempts?.record(route.kind)
        if route.kind == .tailscale {
            return SlowIgnoringCancellationTransport()
        }
        let transport = LivenessTransport(router: router)
        box.set(transport)
        return transport
    }
}
