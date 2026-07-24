import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Web Inspector target catalog")
struct SimulatorWebInspectorTargetCatalogTests {
    @Test("Application and page listings produce typed targets")
    func targetParsing() throws {
        var catalog = SimulatorWebInspectorTargetCatalog()
        catalog.apply(Self.applicationList(), ownConnectionIdentifier: "OURS")
        catalog.apply(Self.pageListing(connectionIdentifier: "OTHER"), ownConnectionIdentifier: "OURS")

        let target = try #require(catalog.targets.first)
        #expect(target.id == "APP|7")
        #expect(target.title == "Fixture")
        #expect(target.url == "https://example.test")
        #expect(target.type == "WIRTypeWebPage")
        #expect(target.applicationName == "Example")
        #expect(target.bundleIdentifier == "com.example.app")
        #expect(target.isInUse)
    }

    @Test("Our own connection does not mark a target in use")
    func ownConnection() throws {
        var catalog = SimulatorWebInspectorTargetCatalog()
        catalog.apply(Self.applicationList(), ownConnectionIdentifier: "OURS")
        catalog.apply(Self.pageListing(connectionIdentifier: "OURS"), ownConnectionIdentifier: "OURS")
        #expect(try #require(catalog.targets.first).isInUse == false)
    }

    @Test("Target replacement and application disconnect remove closed pages")
    func targetCloseCleanup() {
        var catalog = SimulatorWebInspectorTargetCatalog()
        catalog.apply(Self.applicationList(), ownConnectionIdentifier: "OURS")
        catalog.apply(Self.pageListing(connectionIdentifier: nil), ownConnectionIdentifier: "OURS")
        #expect(catalog.targets.count == 1)

        catalog.apply(Self.pageListing(connectionIdentifier: nil, pages: [:]), ownConnectionIdentifier: "OURS")
        #expect(catalog.targets.isEmpty)
        catalog.apply(Self.pageListing(connectionIdentifier: nil), ownConnectionIdentifier: "OURS")
        catalog.apply([
            "__selector": "_rpc_applicationDisconnected:",
            "__argument": ["WIRApplicationIdentifierKey": "APP"],
        ], ownConnectionIdentifier: "OURS")
        #expect(catalog.targets.isEmpty)
    }

    @Test("Identical listings are semantic no-ops")
    func duplicateListing() {
        var catalog = SimulatorWebInspectorTargetCatalog()
        let appliedApplications = catalog.apply(
            Self.applicationList(),
            ownConnectionIdentifier: "OURS"
        )
        let appliedListing = catalog.apply(
            Self.pageListing(connectionIdentifier: nil),
            ownConnectionIdentifier: "OURS"
        )
        let appliedDuplicate = catalog.apply(
            Self.pageListing(connectionIdentifier: nil),
            ownConnectionIdentifier: "OURS"
        )
        #expect(appliedApplications)
        #expect(appliedListing)
        #expect(!appliedDuplicate)
    }

    @Test("Target count and retained strings stay within worker frame budgets")
    func boundedListing() throws {
        var catalog = SimulatorWebInspectorTargetCatalog()
        catalog.apply(Self.applicationList(), ownConnectionIdentifier: "OURS")
        let oversized = String(repeating: "x", count: 32 * 1_024)
        let pages = Dictionary(uniqueKeysWithValues: (0..<2_000).map { index in
            (String(index), [
                "WIRPageIdentifierKey": index,
                "WIRTitleKey": oversized,
                "WIRURLKey": oversized,
                "WIRTypeKey": oversized,
            ] as [String: Any])
        })

        catalog.apply(
            Self.pageListing(connectionIdentifier: nil, pages: pages),
            ownConnectionIdentifier: "OURS"
        )

        #expect(catalog.targets.count <= SimulatorWebInspectorTargetCatalog.maximumTargetCount)
        let target = try #require(catalog.targets.first)
        #expect(target.title.utf8.count <= SimulatorWebInspectorTargetCatalog.maximumFieldBytes + 2)
        #expect(target.url.utf8.count <= SimulatorWebInspectorTargetCatalog.maximumFieldBytes + 2)
        #expect(target.type.utf8.count <= SimulatorWebInspectorTargetCatalog.maximumFieldBytes + 2)
        let encoded = try JSONEncoder().encode(
            SimulatorWorkerOutbound.webInspectorTargets(requestID: UUID(), catalog.targets)
        )
        #expect(encoded.count < SimulatorLengthPrefixedMessageChannel.maximumFrameLength)
    }

    private static func applicationList() -> [String: Any] {
        [
            "__selector": "_rpc_reportConnectedApplicationList:",
            "__argument": [
                "WIRApplicationDictionaryKey": [
                    "APP": [
                        "WIRApplicationBundleIdentifierKey": "com.example.app",
                        "WIRApplicationNameKey": "Example",
                        "WIRIsApplicationProxyKey": false,
                    ],
                ],
            ],
        ]
    }

    private static func pageListing(
        connectionIdentifier: String?,
        pages: [String: Any]? = nil
    ) -> [String: Any] {
        var page: [String: Any] = [
            "WIRPageIdentifierKey": 7,
            "WIRTitleKey": "Fixture",
            "WIRURLKey": "https://example.test",
            "WIRTypeKey": "WIRTypeWebPage",
        ]
        if let connectionIdentifier {
            page["WIRConnectionIdentifierKey"] = connectionIdentifier
        }
        return [
            "__selector": "_rpc_applicationSentListing:",
            "__argument": [
                "WIRApplicationIdentifierKey": "APP",
                "WIRListingKey": pages ?? ["1": page],
            ],
        ]
    }
}
