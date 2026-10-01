import CmuxSwiftRender

/// The worker's reply to an ``InterpreterRequest``: the interpreted
/// ``RenderNode`` tree, or `nil` when the source produced no supported view.
///
/// A crash, timeout, or protocol error in the worker produces *no* response at
/// all; the host treats the absence (its waiter failing) as "render
/// unavailable" and shows its error/empty state, so an interpreter defect can
/// never take down the host process.
public struct InterpreterResponse: Codable, Sendable {
    /// Echoes the originating ``InterpreterRequest/id``.
    public let id: UInt64
    /// The interpreted view tree, or `nil` if nothing supported was found.
    public let node: RenderNode?

    public init(id: UInt64, node: RenderNode?) {
        self.id = id
        self.node = node
    }
}
