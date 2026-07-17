import CMUXMobileCore

struct MobileDiffsTestTransportFactory: CmxByteTransportFactory {
    let host: MobileDiffsTestHost

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        MobileDiffsTestTransport(host: host)
    }
}
