/// Opens byte streams to a backend's host.
///
/// The transport is chosen here, per machine: a Unix socket for the backend
/// on this Mac, a relay lane for a backend on the paired Mac.
public protocol ConversationStreamOpening: Sendable {
    /// Opens a new stream.
    /// - Parameter purpose: What the stream is for.
    /// - Returns: A connected stream.
    /// - Throws: When the host cannot be reached.
    func open(_ purpose: ConversationStreamPurpose) async throws -> any ConversationByteStream
}
