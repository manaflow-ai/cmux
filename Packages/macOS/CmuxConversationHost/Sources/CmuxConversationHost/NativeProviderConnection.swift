public import CmuxConversation

/// Maps a transport stream and command payloads for one provider adapter.
actor NativeProviderConnection: ConversationProviderConnection {
    nonisolated let events: AsyncThrowingStream<ConversationProviderEvent, any Error>
    private let continuation: AsyncThrowingStream<ConversationProviderEvent, any Error>.Continuation
    private let transport: any ConversationNativeTransport
    private let mapIncoming: @Sendable (ConversationJSONValue) -> ConversationProviderEvent
    private let mapCommand: @Sendable (ConversationCommand) throws -> ConversationJSONValue
    private var reader: Task<Void, Never>?
    private var closed = false

    init(transport: any ConversationNativeTransport, mapIncoming: @escaping @Sendable (ConversationJSONValue) -> ConversationProviderEvent, mapCommand: @escaping @Sendable (ConversationCommand) throws -> ConversationJSONValue) {
        self.transport = transport
        self.mapIncoming = mapIncoming
        self.mapCommand = mapCommand
        let (stream, continuation) = AsyncThrowingStream<ConversationProviderEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1_024))
        self.events = stream
        self.continuation = continuation
        reader = Task { [weak self] in await self?.read(source: transport.messages) }
    }

    private func read(source: AsyncThrowingStream<ConversationJSONValue, any Error>) async {
        do {
            for try await message in source {
                guard !closed else { return }
                if case .dropped = continuation.yield(mapIncoming(message)) { await fail(ConversationProviderError.unavailable("Provider event buffer overflow; replay required")); return }
            }
            await fail(ConversationProviderError.unavailable("Provider connection ended"))
        } catch { await fail(error) }
    }

    private func fail(_ error: any Error) {
        guard !closed else { return }
        closed = true; continuation.finish(throwing: error)
    }

    func providerSessionID() async -> String? { nil }
    func capabilities() async -> ConversationCapabilities? { nil }
    func send(_ command: ConversationCommand) async throws {
        guard !closed else { throw ConversationProviderError.unavailable("Provider connection is closed") }
        _ = try await transport.send(try mapCommand(command))
    }
    func close() async { guard !closed else { return }; closed = true; reader?.cancel(); reader = nil; continuation.finish(); await transport.close() }
}
