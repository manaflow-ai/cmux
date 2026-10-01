/// A backend-specific item the core model does not know how to show.
///
/// A GUI renders it only when it has registered a renderer for its
/// ``namespace`` and ``type``; otherwise it may show nothing. This is how a
/// new backend's own integrations reach the GUI without changing the core.
public struct ExtensionItem: Hashable, Sendable {
    /// The backend family that defines it, such as `acpmux`.
    public var namespace: String
    /// The item type within the namespace.
    public var type: String
    /// The backend's payload.
    public var payload: JSONValue

    /// Creates an extension item.
    /// - Parameters:
    ///   - namespace: The defining backend family.
    ///   - type: The item type.
    ///   - payload: The backend's payload.
    public init(namespace: String, type: String, payload: JSONValue) {
        self.namespace = namespace
        self.type = type
        self.payload = payload
    }
}
