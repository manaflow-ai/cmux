import Foundation
@testable import CmuxSimulatorWorker

@MainActor
final class SuccessfulWebInspectorTransport: SimulatorWebInspectorTransport {
    nonisolated let messages: AsyncStream<Data> = AsyncStream { _ in }
    weak var service: SimulatorWebInspectorService?
    let respondsToCensus: Bool
    let respondsToListings: Bool
    let applicationIdentifier: String
    let pageIdentifier: UInt64
    private(set) var sentSelectors: [String] = []

    init(
        service: SimulatorWebInspectorService,
        respondsToCensus: Bool = true,
        respondsToListings: Bool = true,
        applicationIdentifier: String = "APP",
        pageIdentifier: UInt64 = 7
    ) {
        self.service = service
        self.respondsToCensus = respondsToCensus
        self.respondsToListings = respondsToListings
        self.applicationIdentifier = applicationIdentifier
        self.pageIdentifier = pageIdentifier
    }

    func send(propertyList: [String: Any]) throws {
        let selector = propertyList["__selector"] as? String
        if let selector { sentSelectors.append(selector) }
        if selector == "_rpc_getConnectedApplications:" {
            guard respondsToCensus else { return }
            deliver([
                "__selector": "_rpc_reportConnectedApplicationList:",
                "__argument": [
                    "WIRApplicationDictionaryKey": [
                        applicationIdentifier: [
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
                    "WIRApplicationIdentifierKey": applicationIdentifier,
                    "WIRListingKey": [
                        "\(pageIdentifier)": [
                            "WIRPageIdentifierKey": pageIdentifier,
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
                "WIRApplicationIdentifierKey": applicationIdentifier,
                "WIRPageIdentifierKey": pageIdentifier,
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
                "WIRApplicationIdentifierKey": applicationIdentifier,
                "WIRListingKey": [
                    "\(pageIdentifier)": [
                        "WIRPageIdentifierKey": pageIdentifier,
                        "WIRTitleKey": "Fixture",
                        "WIRURLKey": "https://example.test",
                        "WIRTypeKey": "WIRTypeWebPage",
                    ],
                ],
            ],
        ])
    }
}
