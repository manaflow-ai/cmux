import Foundation

/// One floating pane of a screen (`floating-panes-v1`): a leaf of the
/// screen's layout that the tiled layout leaves out, shown above the tiled
/// panes in `frame`. `Screen.floating` lists them back to front.
public struct FloatingPaneSnapshot: Sendable, Hashable, Decodable {
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

    public var pane: PaneID
    public var frame: Frame

    public init(pane: PaneID, frame: Frame) {
        self.pane = pane
        self.frame = frame
    }

    enum CodingKeys: String, CodingKey { case pane, x, y, w, h }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pane = try c.decode(PaneID.self, forKey: .pane)
        frame = Frame(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y),
                      w: try c.decode(Double.self, forKey: .w), h: try c.decode(Double.self, forKey: .h))
    }

    /// The list at `key`. A list that does not decode is no list: every pane
    /// is still a leaf of the layout, so the screen shows them tiled.
    static func list<Key: CodingKey>(in container: KeyedDecodingContainer<Key>, forKey key: Key) -> [FloatingPaneSnapshot] {
        ((try? container.decodeIfPresent([FloatingPaneSnapshot].self, forKey: key)) ?? nil) ?? []
    }
}
