import CMUXMobileCore
import CmuxMobileRPC

struct FailingPoolTransportFactory: CmxByteTransportFactory {
    let attempts: PoolTransportAttemptCounter

    func makeTransport(
        for _: CmxAttachRoute
    ) throws -> any CmxByteTransport {
        attempts.increment()
        throw MobileShellConnectionError.connectionClosed
    }
}
