public import Foundation
public import CmuxConversation

/// A bidirectional JSON transport connected to a native provider process or server.
public protocol ConversationNativeTransport: Sendable {
    /// Incoming provider messages in native JSON form.
    var messages: AsyncThrowingStream<ConversationJSONValue, any Error> { get }
    /// Sends one native JSON request or notification and optionally returns its response.
    func send(_ payload: ConversationJSONValue) async throws -> ConversationJSONValue?
    /// Closes the underlying process or network connection.
    func close() async
}

/// Creates native transports for a trusted session target.
public protocol ConversationNativeTransportFactory: Sendable {
    /// Opens a provider transport for the requested target.
    func make(provider: ConversationProvider, session: ConversationSession, target: ConversationLaunchTarget) async throws -> any ConversationNativeTransport
}

/// A provider adapter that maps a native JSON stream into normalized events.
public protocol NativeConversationAdapter: ConversationProviderAdapter {}
