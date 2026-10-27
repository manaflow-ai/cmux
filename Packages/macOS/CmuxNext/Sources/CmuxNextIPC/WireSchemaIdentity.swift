import CmuxNextWireDigest

/// Which schema this build compiled: the protocol names, versions, method counts and content
/// digests of cmux-tui/spec/sdk-schema.json and cmux-tui/spec/resource-operations-v2.json.
///
/// `WireSchemaIdentity.built` is written at build time by CmuxNextWireGen (through
/// CmuxNextWireGenPlugin) and is never in git; cmux-ipc's build.rs writes the same values as
/// `SCHEMA_IDENTITY`, so equal identities mean the Swift and Rust bindings came from the same
/// schema bytes (plans/cmux-next/chrome-parity/p05-ipc.md section 3.3, task 027).
public struct WireSchemaIdentity: Sendable, Equatable {
    /// `protocol.name` of sdk-schema.json (the v12 mux protocol).
    public let muxProtocol: String
    /// `protocol.version` of sdk-schema.json.
    public let muxProtocolVersion: UInt64
    /// `protocol` of resource-operations-v2.json.
    public let resourceProtocol: String
    /// Keys of `commands` in sdk-schema.json.
    public let commandCount: Int
    /// Keys of `events` in sdk-schema.json.
    public let eventCount: Int
    /// Keys of `operations` in resource-operations-v2.json.
    public let resourceOperationCount: Int
    /// Keys of `local_operations` in resource-operations-v2.json.
    public let localOperationCount: Int
    /// ``digest(of:)`` of sdk-schema.json's bytes.
    public let sdkSchemaDigest: UInt64
    /// ``digest(of:)`` of resource-operations-v2.json's bytes.
    public let resourceOperationsDigest: UInt64

    public init(
        muxProtocol: String,
        muxProtocolVersion: UInt64,
        resourceProtocol: String,
        commandCount: Int,
        eventCount: Int,
        resourceOperationCount: Int,
        localOperationCount: Int,
        sdkSchemaDigest: UInt64,
        resourceOperationsDigest: UInt64
    ) {
        self.muxProtocol = muxProtocol
        self.muxProtocolVersion = muxProtocolVersion
        self.resourceProtocol = resourceProtocol
        self.commandCount = commandCount
        self.eventCount = eventCount
        self.resourceOperationCount = resourceOperationCount
        self.localOperationCount = localOperationCount
        self.sdkSchemaDigest = sdkSchemaDigest
        self.resourceOperationsDigest = resourceOperationsDigest
    }

    /// FNV-1a 64 of `bytes` (CmuxNextWireDigest's `WireDigest`), the digest both generators
    /// write (cmux-ipc's `fnv1a64`).
    public static func digest(of bytes: some Sequence<UInt8>) -> UInt64 {
        WireDigest(bytes).value
    }
}
