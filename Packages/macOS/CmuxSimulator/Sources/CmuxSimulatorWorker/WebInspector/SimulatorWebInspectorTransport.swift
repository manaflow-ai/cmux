import Foundation

protocol SimulatorWebInspectorTransport: AnyObject, Sendable {
    var messages: SimulatorWebInspectorMessageStream { get }

    @MainActor
    func send(propertyList: [String: Any]) throws

    @MainActor
    func close()
}
