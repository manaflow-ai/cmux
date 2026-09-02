import Foundation
@testable import CmuxNestedTopology

/// Test double for ``NestedTopologyProviderClient``.
actor StubNestedTopologyProviderClient: NestedTopologyProviderClient {
    private let handshakeHandler: @Sendable () async throws -> NestedProviderHandshake
    private let snapshotHandler: @Sendable () async throws -> NestedTopologySnapshot
    nonisolated private let eventsHandler: @Sendable () -> AsyncThrowingStream<NestedTopologyEvent, any Error>
    private let focusHandler: (@Sendable (NestedNodeID) async throws -> Void)?

    private(set) var handshakeCount = 0
    private(set) var snapshotCount = 0
    private(set) var focusCount = 0
    private(set) var lastFocusedNodeID: NestedNodeID?
    private var associations = NestedAssociationStore()

    init(
        handshake: @escaping @Sendable () async throws -> NestedProviderHandshake,
        snapshot: @escaping @Sendable () async throws -> NestedTopologySnapshot,
        events: @escaping @Sendable () -> AsyncThrowingStream<NestedTopologyEvent, any Error> = {
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        },
        focus: (@Sendable (NestedNodeID) async throws -> Void)? = nil
    ) {
        self.handshakeHandler = handshake
        self.snapshotHandler = snapshot
        self.eventsHandler = events
        self.focusHandler = focus
    }

    func handshake() async throws -> NestedProviderHandshake {
        handshakeCount += 1
        return try await handshakeHandler()
    }

    func snapshot() async throws -> NestedTopologySnapshot {
        snapshotCount += 1
        return try await snapshotHandler()
    }

    nonisolated func events() -> AsyncThrowingStream<NestedTopologyEvent, any Error> {
        eventsHandler()
    }

    func focus(nodeID: NestedNodeID) async throws {
        focusCount += 1
        lastFocusedNodeID = nodeID
        if let focusHandler {
            try await focusHandler(nodeID)
        }
    }

    /// In-memory association store — starts empty and is never rehydrated from session intents.
    func associationStore() -> NestedAssociationStore {
        associations
    }

    func setAssociationStore(_ store: NestedAssociationStore) {
        associations = store
    }
}

/// Factory that returns a prepared stub client (ignores socket configuration).
struct StubNestedTopologyProviderClientFactory: NestedTopologyProviderClientFactory, Sendable {
    let client: StubNestedTopologyProviderClient

    func makeHerdrClient(
        configuration: HerdrNestedTopologyClientConfiguration
    ) -> any NestedTopologyProviderClient {
        client
    }
}

/// Validator stub that returns a fixed endpoint / identity mismatch on demand.
struct StubEndpointValidator: NestedEndpointValidating, Sendable {
    var preConnectResult: Result<NestedAttachmentEndpoint, NestedEndpointSecurityError>
    var revalidateError: NestedEndpointSecurityError?

    func validatePreConnect(path: String) throws -> NestedAttachmentEndpoint {
        _ = path
        switch preConnectResult {
        case .success(let endpoint):
            return endpoint
        case .failure(let error):
            throw error
        }
    }

    func revalidateIdentity(
        path: String,
        expected: NestedUnixSocketFileIdentity
    ) throws {
        _ = path
        _ = expected
        if let revalidateError {
            throw revalidateError
        }
    }
}

enum AttachmentTestFixtures {
    static let surfaceA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    static let surfaceB = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    static let workspaceA = "workspace:1"
    static let workspaceB = "workspace:2"

    static let endpoint = NestedAttachmentEndpoint(
        canonicalPath: "/tmp/cmux-nested-test.sock",
        fileIdentity: NestedUnixSocketFileIdentity(deviceID: 1, inode: 2),
        ownerUID: 501,
        permissionBits: 0o600
    )

    static func handshake(
        instance: String = "instance-a",
        capabilities: NestedCapabilitySet = HerdrProtocol17Compatibility.readCapabilities,
        instanceIdentityIsDurable: Bool = true
    ) -> NestedProviderHandshake {
        NestedProviderHandshake(
            providerKind: .herdr,
            providerInstanceID: NestedProviderInstanceID(rawValue: instance),
            version: "0.7.0",
            protocolNumber: 17,
            capabilities: capabilities,
            instanceIdentityIsDurable: instanceIdentityIsDurable
        )
    }

    static func snapshot(
        attachmentID: UUID,
        hostStableSurfaceID: UUID,
        instance: String = "instance-a",
        paneRawID: String = "w1:p1"
    ) -> NestedTopologySnapshot {
        let instanceID = NestedProviderInstanceID(rawValue: instance)
        let workspaceID = NestedNodeID(
            providerKind: .herdr,
            providerInstanceID: instanceID,
            kind: .workspace,
            rawID: "w1"
        )
        let tabID = NestedNodeID(
            providerKind: .herdr,
            providerInstanceID: instanceID,
            kind: .tab,
            rawID: "w1:t1"
        )
        let paneID = NestedNodeID(
            providerKind: .herdr,
            providerInstanceID: instanceID,
            kind: .pane,
            rawID: paneRawID
        )
        return NestedTopologySnapshot(
            attachmentID: attachmentID,
            hostStableSurfaceID: hostStableSurfaceID,
            provider: handshake(instance: instance),
            workspaces: [
                NestedWorkspaceNode(id: workspaceID, displayTitle: "W", orderIndex: 0),
            ],
            tabs: [
                NestedTabNode(
                    id: tabID,
                    workspaceID: workspaceID,
                    displayTitle: "T",
                    orderIndex: 0
                ),
            ],
            panes: [
                NestedPaneNode(
                    id: paneID,
                    tabID: tabID,
                    displayTitle: "P",
                    orderIndex: 0
                ),
            ],
            agents: [],
            focus: NestedFocus(workspaceID: workspaceID, tabID: tabID, paneID: paneID, agentID: nil)
        )
    }

    static func makeHandoffDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-nested-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
