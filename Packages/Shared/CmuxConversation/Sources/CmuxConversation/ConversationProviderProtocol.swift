public import Foundation

/// A provider event before the broker assigns a durable sequence.
public struct ConversationProviderEvent: Codable, Hashable, Sendable {
    /// Native provider lifecycle category.
    public let kind: ConversationEventKind
    /// Provider item identifier, when available.
    public let itemID: ConversationItemID?
    /// Provider turn identifier, when available.
    public let turnID: ConversationTurnID?
    /// Normalized item kind.
    public let itemKind: ConversationItemKind?
    /// Nil replaces the item; a mode carries only new text or output bytes.
    public let itemUpdate: ConversationItemUpdateMode?
    /// Semantic message role when known.
    public let role: String?
    /// Text or state label.
    public let text: String?
    /// Tool details.
    public let tool: ConversationTool?
    /// Plan details.
    public let plan: ConversationPlan?
    /// Diff details.
    public let diff: ConversationDiff?
    /// Artifact details.
    public let artifact: ConversationArtifact?
    /// Usage details.
    public let usage: ConversationUsage?
    /// Request payload.
    public let request: ConversationRequest?
    /// Run/turn state.
    public let state: String?
    /// Original native provider payload.
    public let rawPayload: ConversationJSONValue?

    /// Creates a provider event for broker normalization.
    public init(kind: ConversationEventKind, itemID: ConversationItemID? = nil, turnID: ConversationTurnID? = nil, itemKind: ConversationItemKind? = nil, itemUpdate: ConversationItemUpdateMode? = nil, role: String? = nil, text: String? = nil, tool: ConversationTool? = nil, plan: ConversationPlan? = nil, diff: ConversationDiff? = nil, artifact: ConversationArtifact? = nil, usage: ConversationUsage? = nil, request: ConversationRequest? = nil, state: String? = nil, rawPayload: ConversationJSONValue? = nil) { self.kind = kind; self.itemID = itemID; self.turnID = turnID; self.itemKind = itemKind; self.itemUpdate = itemUpdate; self.role = role; self.text = text; self.tool = tool; self.plan = plan; self.diff = diff; self.artifact = artifact; self.usage = usage; self.request = request; self.state = state; self.rawPayload = rawPayload }
}

/// A connected provider session owned by the broker.
public protocol ConversationProviderConnection: Sendable {
    /// Provider-native session identity, when the protocol exposes one.
    func providerSessionID() async -> String?
    /// Runtime capability catalog learned from the native protocol, when available.
    func capabilities() async -> ConversationCapabilities?
    /// Native events emitted by this connection.
    var events: AsyncThrowingStream<ConversationProviderEvent, any Error> { get }
    /// Sends a command using the provider's native protocol.
    func send(_ command: ConversationCommand) async throws
    /// Closes the provider process or transport.
    func close() async
}

/// An adapter that manages one provider's native session protocol.
public protocol ConversationProviderAdapter: Sendable {
    /// Provider represented by this adapter.
    var provider: ConversationProvider { get }
    /// Capability declaration for this adapter implementation.
    var capabilities: ConversationCapabilities { get }
    /// Opens a provider session.
    func open(session: ConversationSession, target: ConversationLaunchTarget) async throws -> any ConversationProviderConnection
}

/// Provider lifecycle and command failures surfaced without pretending success.
public enum ConversationProviderError: Error, Codable, Hashable, Sendable, CustomStringConvertible {
    /// The adapter cannot support the requested provider target.
    case unsupported(String)
    /// Native provider rejected the command.
    case rejected(String)
    /// Provider process or transport is unavailable.
    case unavailable(String)
    /// Native event could not be normalized; raw payload remains journaled.
    case malformed(String)
    /// The provider generation no longer matches.
    case staleGeneration

    public var description: String { switch self { case .unsupported(let v): "unsupported: \(v)"; case .rejected(let v): "rejected: \(v)"; case .unavailable(let v): "unavailable: \(v)"; case .malformed(let v): "malformed: \(v)"; case .staleGeneration: "stale generation" } }
}

public extension ConversationProviderConnection {
    /// Providers without a resumable native identifier return nil.
    func providerSessionID() async -> String? { nil }
    /// Providers without runtime capability negotiation return their static declaration.
    func capabilities() async -> ConversationCapabilities? { nil }
}
