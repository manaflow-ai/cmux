import CMUXMobileCore
import Foundation

/// Synchronous test probe: every access to mutable state is serialized by `lock`,
/// and no locked region crosses an async suspension point.
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
