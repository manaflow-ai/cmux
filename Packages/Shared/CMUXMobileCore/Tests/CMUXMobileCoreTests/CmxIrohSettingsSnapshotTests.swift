import Foundation
import Testing

@testable import CMUXMobileCore

@Suite
struct CmxIrohSettingsSnapshotTests {
    @Test
    func activeRuntimeStatusPreservesOnlyRedactedPathLabels() {
        #expect(CmxIrohSettingsSnapshot.RuntimeStatus(
            activePath: .direct
        ) == .direct)
        #expect(CmxIrohSettingsSnapshot.RuntimeStatus(
            activePath: .privateNetwork
        ) == .privateNetwork(displayName: ""))
        #expect(CmxIrohSettingsSnapshot.RuntimeStatus(
            activePath: .managedRelay(provider: "cmux", region: "us-east1")
        ) == .relayed(provider: "cmux", region: "us-east1"))
        #expect(CmxIrohSettingsSnapshot.RuntimeStatus(
            activePath: .customRelay(
                displayName: "Office Relay",
                provider: "My Network",
                region: "Office"
            )
        ) == .relayed(provider: "My Network", region: "Office"))
    }

    @Test func snapshotCopiesMutableInputsIntoAnImmutableValue() {
        var managedRelays = [Self.managedRelay(id: "use1")]
        var staleRelayIDs: Set<String> = ["retired"]
        let snapshot = CmxIrohSettingsSnapshot(
            runtimeStatus: .relayed(provider: "cmux", region: "us-east"),
            selectedTransportPath: .managedRelay(provider: "cmux", region: "us-east"),
            preference: .managed(["use1"]),
            managedRelays: managedRelays,
            customRelays: [],
            policySource: .server,
            policySequence: 42,
            staleRelayIDs: staleRelayIDs
        )

        managedRelays.removeAll()
        staleRelayIDs.removeAll()

        #expect(snapshot.managedRelays.map(\.id) == ["use1"])
        #expect(snapshot.staleRelayIDs == ["retired"])
        #expect(snapshot.preference == .managed(["use1"]))
        #expect(snapshot.selectedTransportPath == .managedRelay(
            provider: "cmux",
            region: "us-east"
        ))
    }

    @Test func customRelayProjectionExposesCredentialStateWithoutSecretMaterial() {
        let relay = CmxIrohSettingsSnapshot.CustomRelay(
            id: "personal",
            displayName: "Personal Relay",
            provider: "Self-hosted",
            region: "Home",
            url: "https://relay.example.test",
            authMode: .deviceSecret,
            credentialState: .configured
        )
        let snapshot = CmxIrohSettingsSnapshot(
            runtimeStatus: .active,
            preference: .custom,
            managedRelays: [],
            customRelays: [relay],
            policySource: .cached
        )

        #expect(snapshot.customRelays == [relay])
        #expect(relay.credentialState == .configured)
        #expect(secretBearingLabels(in: snapshot).isEmpty)
    }

    @Test func debugTransportProjectionPreservesAllThreeVerificationModes() {
        for mode in CmxIrohTransportVerificationMode.allCases {
            let snapshot = CmxIrohSettingsSnapshot(
                runtimeStatus: .active,
                preference: .automatic,
                managedRelays: [],
                customRelays: [],
                policySource: .server,
                debugTransportVerificationMode: mode
            )

            #expect(snapshot.debugTransportVerificationMode == mode)
            #expect(snapshot.debugRelayOnlyEnabled == (mode == .relayOnly))
        }
    }

    @Test func managedPreferenceRequiresOneToSixteenSafeRelayIdentifiers() throws {
        #expect(throws: CmxIrohRelayPreferenceDraftError.self) {
            try CmxIrohRelayPreferenceDraft.managed([]).validated()
        }
        #expect(throws: CmxIrohRelayPreferenceDraftError.self) {
            try CmxIrohRelayPreferenceDraft.managed(Set((0 ... 16).map { "relay-\($0)" })).validated()
        }
        #expect(throws: CmxIrohRelayPreferenceDraftError.self) {
            try CmxIrohRelayPreferenceDraft.managed(["relay/unsafe"]).validated()
        }

        #expect(try CmxIrohRelayPreferenceDraft.managed(["use1-1", "provider.region_2"]).validated()
            == .managed(["use1-1", "provider.region_2"]))
        #expect(try CmxIrohRelayPreferenceDraft.automatic.validated() == .automatic)
        #expect(try CmxIrohRelayPreferenceDraft.custom.validated() == .custom)
    }

    private static func managedRelay(id: String) -> CmxIrohSettingsSnapshot.ManagedRelay {
        CmxIrohSettingsSnapshot.ManagedRelay(
            id: id,
            provider: "cmux",
            region: "us-east",
            url: "https://\(id).relay.example.test",
            isSelected: true
        )
    }

    private func secretBearingLabels(in value: Any) -> [String] {
        let forbiddenFragments = ["secret", "token", "credentialvalue", "authorization"]
        var matches: [String] = []

        func visit(_ value: Any) {
            let mirror = Mirror(reflecting: value)
            for child in mirror.children {
                if let label = child.label {
                    let normalized = label.lowercased()
                    if forbiddenFragments.contains(where: normalized.contains) {
                        matches.append(label)
                    }
                }
                visit(child.value)
            }
        }

        visit(value)
        return matches
    }
}
