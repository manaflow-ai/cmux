import Foundation

// The struct is generated from the schema's `FloatingPane` (cmux-tui/bindings/codegen/swift_app,
// family Tree): the wire's flat `{pane, x, y, w, h}`. This file groups the four numbers as `frame`.
extension FloatingPaneSnapshot {
    /// Where a floating pane is, as fractions of the screen's pane area:
    /// the top left corner and the size, as the daemon sent it; not checked
    /// against the layout, the range or repeats. The daemon bounds each
    /// number (each is in `0...1` today).
    public struct Frame: Sendable, Hashable {
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double

        public init(x: Double, y: Double, w: Double, h: Double) {
            self.x = x
            self.y = y
            self.w = w
            self.h = h
        }
    }

    public var frame: Frame {
        get { Frame(x: x, y: y, w: w, h: h) }
        set { (x, y, w, h) = (newValue.x, newValue.y, newValue.w, newValue.h) }
    }

    public init(pane: PaneID, frame: Frame) {
        self.init(pane: pane, x: frame.x, y: frame.y, w: frame.w, h: frame.h)
    }

    /// The list at `key`. A list that does not decode is no list: every pane
    /// is still a leaf of the layout, so the screen shows them tiled.
    static func list<Key: CodingKey>(in container: KeyedDecodingContainer<Key>, forKey key: Key) -> [FloatingPaneSnapshot] {
        ((try? container.decodeIfPresent([FloatingPaneSnapshot].self, forKey: key)) ?? nil) ?? []
    }
}
