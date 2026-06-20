import CMUXMobileCore

struct ChecklistErrorTransportFactory: CmxByteTransportFactory {
    let code: String?
    let message: String

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        ChecklistErrorTransport(code: code, message: message)
    }
}
