import Foundation

protocol SimulatorWebInspectorTransport: AnyObject, Sendable {
    var messages: AsyncStream<Data> { get }

    @MainActor
    func send(propertyList: [String: Any]) throws

    @MainActor
    func close()
}
