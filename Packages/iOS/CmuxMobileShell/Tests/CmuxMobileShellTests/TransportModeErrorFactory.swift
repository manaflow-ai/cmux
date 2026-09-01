import CMUXMobileCore
import CmuxMobileTransport

/// Produces a selected transport-mode error for route-selection tests.
struct TransportModeErrorFactory: CmxByteTransportFactory {
    let error: CmxTransportModeError

    func makeTransport(for _: CmxAttachRoute) throws -> any CmxByteTransport {
        throw error
    }

    func makeTransport(
        for _: CmxByteTransportRequest
    ) throws -> any CmxByteTransport {
        throw error
    }
}
