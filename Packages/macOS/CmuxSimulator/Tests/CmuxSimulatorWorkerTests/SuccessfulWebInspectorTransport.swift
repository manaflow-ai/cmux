import Foundation
@testable import CmuxSimulatorWorker

@MainActor
final class SuccessfulWebInspectorTransport: SimulatorWebInspectorTransport {
    nonisolated let messages: AsyncStream<Data> = AsyncStream { _ in }
    weak var service: SimulatorWebInspectorService?
    let respondsToCensus: Bool
    let respondsToListings: Bool

    init(
        service: SimulatorWebInspectorService,
        respondsToCensus: Bool = true,
        respondsToListings: Bool = true
    ) {
        self.service = service
        self.respondsToCensus = respondsToCensus
        self.respondsToListings = respondsToListings
    }

    func send(propertyList: [String: Any]) throws {
        let selector = propertyList["__selector"] as? String
        if selector == "_rpc_getConnectedApplications:" {
            guard respondsToCensus else { return }
            deliver([
                "__selector": "_rpc_reportConnectedApplicationList:",
                "__argument": [
                    "WIRApplicationDictionaryKey": [
                        "APP": [
                            "WIRApplicationBundleIdentifierKey": "com.example.app",
                            "WIRApplicationNameKey": "Example",
                        ],
                    ],
                ],
            ])
            return
        }
        if selector == "_rpc_forwardGetListing:" {
            guard respondsToListings else { return }
            deliver([
                "__selector": "_rpc_applicationSentListing:",
                "__argument": [
                    "WIRApplicationIdentifierKey": "APP",
                    "WIRListingKey": [
                        "7": [
                            "WIRPageIdentifierKey": 7,
                            "WIRTitleKey": "Fixture",
                            "WIRURLKey": "https://example.test",
                            "WIRTypeKey": "WIRTypeWebPage",
                        ],
                    ],
                ],
            ])
            return
        }
        guard selector == "_rpc_forwardSocketData:",
              let argument = propertyList["__argument"] as? [String: Any],
              let request = argument["WIRSocketDataKey"] as? Data,
              let object = try JSONSerialization.jsonObject(with: request) as? [String: Any],
              let identifier = simulatorWebInspectorInteger(object["id"]),
              let service else { return }
        let response = try JSONSerialization.data(withJSONObject: [
            "id": identifier,
            "result": [:],
        ])
        deliver([
            "__selector": "_rpc_applicationSentData:",
            "__argument": [
                "WIRApplicationIdentifierKey": "APP",
                "WIRPageIdentifierKey": 7,
                "WIRDestinationKey": service.session?.senderIdentifier ?? "",
                "WIRMessageDataKey": response,
            ],
        ])
    }

    private func deliver(_ propertyList: [String: Any]) {
        guard let service,
              let body = try? SimulatorWebInspectorPlistFrameCodec().encodeBody(propertyList)
        else { return }
        Task { @MainActor [weak service] in
            service?.receive(propertyListBody: body)
        }
    }

    func close() {}

    func emitListing() {
        deliver([
            "__selector": "_rpc_applicationSentListing:",
            "__argument": [
                "WIRApplicationIdentifierKey": "APP",
                "WIRListingKey": [
                    "7": [
                        "WIRPageIdentifierKey": 7,
                        "WIRTitleKey": "Fixture",
                        "WIRURLKey": "https://example.test",
                        "WIRTypeKey": "WIRTypeWebPage",
                    ],
                ],
            ],
        ])
    }
}
