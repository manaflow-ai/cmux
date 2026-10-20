import Foundation
@testable import CMUXMobileCore

struct TaggedTransportFactory: CmxByteTransportFactory {
    var tag: String

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        TaggedTransport(tag: tag, route: route)
    }
}

struct RequestTaggedTransportFactory: CmxByteTransportFactory {
    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        TaggedTransport(tag: "route-only", route: route)
    }

    func makeTransport(
        for request: CmxByteTransportRequest
    ) throws -> any CmxByteTransport {
        let mode = request.authorizationMode == .transportAdmission ? "admission" : "stack"
        return TaggedTransport(
            tag: "\(request.expectedPeerDeviceID ?? "missing"):\(mode)",
            route: request.route
        )
    }
}

struct TaggedTransport: CmxByteTransport {
    var tag: String
    var route: CmxAttachRoute

    func connect() async throws {}

    func receive() async throws -> Data? {
        nil
    }

    func send(_ data: Data) async throws {}

    func close() async {}
}
