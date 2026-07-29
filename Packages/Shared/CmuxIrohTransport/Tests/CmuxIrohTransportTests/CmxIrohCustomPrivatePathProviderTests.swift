import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

extension CmxIrohRegistryContextProviderTests {
    @Test
    func probeContextUsesExactlyOneAuthenticatedCustomAddress() async throws {
        let fixture = try RegistryFixture()
        let profile = try CmxIrohNetworkProfileKey(
            source: .customVPN,
            profileID: opaqueProfileID("custom-private-probe")
        )
        let probePath = try CmxIrohCustomPrivatePathBootstrap(
            address: CmxIrohCustomPrivateAddress("10.0.0.9"),
            networkProfile: profile
        )
        let configuredPath = try CmxIrohCustomPrivatePathBootstrap(
            address: CmxIrohCustomPrivateAddress("10.0.0.8"),
            networkProfile: profile
        )
        let relay = try CmxIrohPathHint(
            kind: .relayURL,
            value: fixture.relayURL,
            source: .native,
            privacyScope: .publicInternet
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: TestIrohRegistryBroker(
                discovery: try fixture.discovery(
                    targetHints: [],
                    targetDirectPorts: ["ipv4": 50_909]
                ),
                pairGrantResponses: [try fixture.pairGrantResponse(
                    issuedAt: fixture.nowSeconds,
                    expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
                )]
            ),
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            networkPathSnapshot: {
                CmxIrohNetworkPathSnapshot(
                    generation: 7,
                    activeNetworkProfiles: []
                )
            },
            customPrivateFallback: { _ in
                [configuredPath]
            },
            now: { fixture.now }
        )

        let context = try await provider.privatePathProbeContext(
            for: fixture.request(hints: [relay]),
            path: probePath
        )

        #expect(context.dialPlan.publicPaths.isEmpty)
        #expect(context.dialPlan.privateFallbackPaths.map(\.value) == [
            "10.0.0.9:50909",
        ])
        #expect(context.dialPlan.privateFallbackPaths.first?.networkProfile == profile)
    }

    @Test
    func probeContextRejectsStaleAuthenticatedPort() async throws {
        let fixture = try RegistryFixture()
        let profile = try CmxIrohNetworkProfileKey(
            source: .customVPN,
            profileID: opaqueProfileID("custom-private-probe")
        )
        let path = try CmxIrohCustomPrivatePathBootstrap(
            address: CmxIrohCustomPrivateAddress("10.0.0.9"),
            networkProfile: profile
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: TestIrohRegistryBroker(
                discovery: try fixture.discovery(
                    targetHints: [],
                    targetDirectPorts: ["ipv4": 50_909],
                    targetLastSeenAt: fixture.now.addingTimeInterval(
                        -(CmxIrohPathHint.maximumPrivateHintTTL + 1)
                    )
                ),
                pairGrantResponses: [try fixture.pairGrantResponse(
                    issuedAt: fixture.nowSeconds,
                    expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
                )]
            ),
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            networkPathSnapshot: {
                CmxIrohNetworkPathSnapshot(
                    generation: 7,
                    activeNetworkProfiles: []
                )
            },
            now: { fixture.now }
        )

        await #expect(throws: CmxIrohPrivatePathProbeDialError.stalePort) {
            try await provider.privatePathProbeContext(
                for: fixture.request(hints: []),
                path: path
            )
        }
    }

    @Test
    func customPrivateAddressesUseAuthenticatedMacPortsAndIdentity() async throws {
        let fixture = try RegistryFixture()
        let profile = try CmxIrohNetworkProfileKey(
            source: .customVPN,
            profileID: opaqueProfileID("custom-private")
        )
        let recorder = try TestCustomPrivateFallbackRecorder(
            paths: ["10.0.0.8", "fd00::8"].map {
                try CmxIrohCustomPrivatePathBootstrap(
                    address: CmxIrohCustomPrivateAddress($0),
                    networkProfile: profile
                )
            }
        )
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(
                targetHints: [],
                targetDirectPorts: ["ipv4": 50_909, "ipv6": 54_750]
            ),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            networkPathSnapshot: {
                CmxIrohNetworkPathSnapshot(
                    generation: 7,
                    activeNetworkProfiles: [profile]
                )
            },
            customPrivateFallback: { deviceID in
                await recorder.paths(for: deviceID)
            },
            now: { fixture.now }
        )

        let context = try await provider.context(for: fixture.request(hints: []))

        #expect(await recorder.requestedDeviceIDs() == [fixture.acceptor.deviceID])
        #expect(context.dialPlan.privateFallbackPaths.map(\.value) == [
            "10.0.0.8:50909",
            "[fd00::8]:54750",
        ])
        #expect(context.dialPlan.privateFallbackPaths.allSatisfy {
            $0.source == .customVPN
                && $0.privacyScope == .privateNetwork
                && $0.networkProfile == profile
        })
        let authorization = try #require(context.privateFallbackAuthorization)
        #expect(authorization.networkPathSnapshot.generation == 7)

        await #expect(throws: CmxIrohRegistryContextError.targetDeviceMismatch) {
            try await provider.context(for: fixture.request(
                hints: [],
                expectedPeerDeviceID: "123e4567-e89b-42d3-a456-426614174099"
            ))
        }
        #expect(await recorder.requestedDeviceIDs() == [fixture.acceptor.deviceID])
    }

    @Test
    func customPrivateAddressCannotGuessMissingOrStaleBrokerPort() async throws {
        let fixture = try RegistryFixture()
        let profile = try CmxIrohNetworkProfileKey(
            source: .customVPN,
            profileID: opaqueProfileID("custom-private")
        )
        let path = try CmxIrohCustomPrivatePathBootstrap(
            address: CmxIrohCustomPrivateAddress("10.0.0.8"),
            networkProfile: profile
        )
        let stale = fixture.now.addingTimeInterval(
            -(CmxIrohPathHint.maximumPrivateHintTTL + 1)
        )
        let cases: [(String, [String: Int]?, Date?)] = [
            ("missing", nil, nil),
            ("wrong family", ["ipv6": 54_750], nil),
            ("stale", ["ipv4": 50_909], stale),
        ]

        for (name, directPorts, lastSeenAt) in cases {
            let broker = TestIrohRegistryBroker(
                discovery: try fixture.discovery(
                    targetHints: [],
                    targetDirectPorts: directPorts,
                    targetLastSeenAt: lastSeenAt
                ),
                pairGrantResponses: [try fixture.pairGrantResponse(
                    issuedAt: fixture.nowSeconds,
                    expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
                )]
            )
            let provider = CmxIrohRegistryContextProvider(
                supervisor: try await fixture.activeSupervisor(),
                broker: broker,
                localBindingExpectation: try fixture.localExpectation(),
                managedRelayURLs: [fixture.relayURL],
                networkPathSnapshot: {
                    CmxIrohNetworkPathSnapshot(
                        generation: 7,
                        activeNetworkProfiles: [profile]
                    )
                },
                customPrivateFallback: { _ in [path] },
                now: { fixture.now }
            )

            let context = try await provider.context(for: fixture.request(hints: []))

            #expect(context.dialPlan.privateFallbackPaths.isEmpty, Comment(rawValue: name))
            #expect(context.privateFallbackAuthorization == nil, Comment(rawValue: name))
        }
    }

    @Test
    func customPrivateConfigurationGenerationChangeRevokesAuthorization() async throws {
        let fixture = try RegistryFixture()
        let profile = try CmxIrohNetworkProfileKey(
            source: .customVPN,
            profileID: opaqueProfileID("custom-private")
        )
        let path = try CmxIrohCustomPrivatePathBootstrap(
            address: CmxIrohCustomPrivateAddress("10.0.0.8"),
            networkProfile: profile
        )
        let customState = TestCustomPrivateSnapshotState(
            CmxIrohCustomPrivatePathSnapshot(
                generation: 2,
                configurations: [],
                activeNetworkProfiles: [profile]
            )
        )
        let composer = CmxIrohNetworkPathSnapshotComposer()
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(
                targetHints: [],
                targetDirectPorts: ["ipv4": 50_909]
            ),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            networkPathSnapshot: {
                await composer.compose(
                    platform: CmxIrohNetworkPathSnapshot(
                        generation: 11,
                        activeNetworkProfiles: []
                    ),
                    custom: await customState.snapshot()
                )
            },
            customPrivateFallback: { _ in [path] },
            now: { fixture.now }
        )
        let context = try await provider.context(for: fixture.request(hints: []))
        let authorization = try #require(context.privateFallbackAuthorization)

        await customState.set(CmxIrohCustomPrivatePathSnapshot(
            generation: 3,
            configurations: [],
            activeNetworkProfiles: []
        ))

        await #expect(throws: CmxIrohPrivateFallbackValidationError.generationChanged) {
            try await provider.validatePrivateFallback(authorization)
        }
    }
}

private actor TestCustomPrivateFallbackRecorder {
    private let configuredPaths: [CmxIrohCustomPrivatePathBootstrap]
    private var deviceIDs: [String] = []

    init(paths: [CmxIrohCustomPrivatePathBootstrap]) throws {
        configuredPaths = paths
    }

    func paths(for deviceID: String) -> [CmxIrohCustomPrivatePathBootstrap] {
        deviceIDs.append(deviceID)
        return configuredPaths
    }

    func requestedDeviceIDs() -> [String] { deviceIDs }
}

private actor TestCustomPrivateSnapshotState {
    private var value: CmxIrohCustomPrivatePathSnapshot

    init(_ value: CmxIrohCustomPrivatePathSnapshot) {
        self.value = value
    }

    func snapshot() -> CmxIrohCustomPrivatePathSnapshot { value }

    func set(_ value: CmxIrohCustomPrivatePathSnapshot) {
        self.value = value
    }
}
