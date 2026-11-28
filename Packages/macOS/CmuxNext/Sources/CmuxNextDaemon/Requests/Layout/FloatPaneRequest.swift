import Foundation

// `float-pane` itself is generated (swift_app/bindings.json, family Layout): its fields, the
// `floating-panes-v1` gate and the wire encoding. What the schema cannot say stays here: the `mode`
// values, the reply's shape and the init that takes a `FloatingPaneSnapshot.Frame`.

extension FloatPaneRequest {
    /// Float (`on`), put back (`off`) or flip (`toggle`, the daemon's default).
    public enum Mode: String, Sendable, Codable { case toggle, on, off }

    public struct Response: Decodable, Sendable, Equatable {
        /// Whether the pane floats after the request.
        public var floating: Bool
        /// False when the request matched the screen and committed nothing.
        public var changed: Bool
    }

    /// A frame (all four of `x`, `y`, `w` and `h`) or none. `frame` has no default so a call with only `pane`
    /// and `mode` stays the generated init's.
    public init(pane: PaneID, mode: Mode? = nil, frame: FloatingPaneSnapshot.Frame?, transaction: UInt64? = nil) {
        self.init(pane: pane, mode: mode, x: frame?.x, y: frame?.y, w: frame?.w, h: frame?.h, transaction: transaction)
    }
}
