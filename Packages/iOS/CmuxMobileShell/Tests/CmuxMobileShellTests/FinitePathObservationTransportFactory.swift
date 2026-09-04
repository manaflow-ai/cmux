import CMUXMobileCore
import CmuxMobileTransport

/// Supplies the deterministic path-observing transport used by diagnostics tests.
struct FinitePathObservationTransportFactory: CmxByteTransportFactory {
    let transport: FinitePathObservationTransport

    func makeTransport(for _: CmxAttachRoute) throws -> any CmxByteTransport {
        transport
    }
}
