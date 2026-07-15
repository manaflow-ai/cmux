import CMUXMobileCore
import Foundation

final class KindRecordingTransportFactory: CmxByteTransportFactory, @unchecked Sendable {
    private let router: LivenessHostRouter
    private let box: TransportBox
    private let failingKinds: Set<CmxAttachTransportKind>
    private let lock = NSLock()
    private var attempts: [CmxAttachTransportKind] = []

    init(
        router: LivenessHostRouter,
        box: TransportBox,
        failingKinds: Set<CmxAttachTransportKind> = []
    ) {
        self.router = router
        self.box = box
        self.failingKinds = failingKinds
    }

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        lock.withLock { attempts.append(route.kind) }
        if failingKinds.contains(route.kind) {
            throw NSError(domain: "IrohStoredReconnectRegressionTests", code: 1)
        }
        let transport = LivenessTransport(router: router)
        box.set(transport)
        return transport
    }

    func attemptedKinds() -> [CmxAttachTransportKind] {
        lock.withLock { attempts }
    }
}
