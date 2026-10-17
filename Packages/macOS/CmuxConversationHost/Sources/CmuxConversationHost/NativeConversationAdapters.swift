public import Foundation
public import CmuxConversation

/// A Codex app-server adapter using JSON-RPC over a native transport.
public struct CodexConversationAdapter: NativeConversationAdapter {
    public let provider: ConversationProvider = .codex
    public let capabilities: ConversationCapabilities
    private let factory: any ConversationNativeTransportFactory

    /// Creates an adapter with an injected native transport factory.
    /// - Parameters:
    ///   - factory: Factory that launches or connects to `codex app-server`.
    ///   - capabilities: Native capabilities advertised to clients.
    public init(factory: any ConversationNativeTransportFactory, capabilities: ConversationCapabilities = ConversationCapabilities(protocolVersion: "codex-app-server", features: ["turn/start", "turn/steer", "turn/interrupt", "approval", "question", "diff", "artifact"], supportsResume: true)) { self.factory = factory; self.capabilities = capabilities }
    public func open(session: ConversationSession, target: ConversationLaunchTarget) async throws -> any ConversationProviderConnection {
        let transport = try await factory.make(provider: provider, session: session, target: target)
        return try await CodexConnection.open(transport: transport, session: session)
    }
}

/// A Claude Code bidirectional streaming adapter.
public struct ClaudeCodeConversationAdapter: NativeConversationAdapter {
    public let provider: ConversationProvider = .claudeCode
    public let capabilities: ConversationCapabilities
    private let factory: any ConversationNativeTransportFactory

    /// Creates an adapter with an injected streaming-json transport factory.
    public init(factory: any ConversationNativeTransportFactory, capabilities: ConversationCapabilities = ConversationCapabilities(protocolVersion: "claude-streaming-json", features: ["streaming", "interrupt", "approval", "question", "child"], supportsResume: true)) { self.factory = factory; self.capabilities = capabilities }
    public func open(session: ConversationSession, target: ConversationLaunchTarget) async throws -> any ConversationProviderConnection {
        let transport = try await factory.make(provider: provider, session: session, target: target)
        return try await ClaudeConnection.open(transport: transport, session: session)
    }
}

/// An OpenCode HTTP/SSE adapter that relies on the current server transport.
public struct OpenCodeConversationAdapter: NativeConversationAdapter {
    public let provider: ConversationProvider = .openCode
    public let capabilities: ConversationCapabilities
    private let factory: any ConversationNativeTransportFactory

    /// Creates an adapter with an injected HTTP/SSE transport factory.
    public init(factory: any ConversationNativeTransportFactory, capabilities: ConversationCapabilities = ConversationCapabilities(protocolVersion: "opencode-http-sse", features: ["session.prompt", "session.abort", "event-stream"], supportsResume: true)) { self.factory = factory; self.capabilities = capabilities }
    public func open(session: ConversationSession, target: ConversationLaunchTarget) async throws -> any ConversationProviderConnection {
        let transport = try await factory.make(provider: provider, session: session, target: target)
        return try await OpenCodeConnection.open(transport: transport, session: session)
    }
}
