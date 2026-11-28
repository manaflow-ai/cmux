import CmuxVNCWebRTC
import CoreGraphics
import Foundation

/// The Mac's cursor on a screen stream, drawn exactly as macOS shows it: its
/// own image (``ScreenCursorShape``) with sizes as fractions of the streamed
/// display, so it lands at the Mac's size at any zoom.
public struct ScreenStreamCursor: Sendable, Equatable {
    public let id: String
    public let image: CGImage
    /// Width and height as fractions of the streamed display.
    public let size: CGSize
    /// The hotspot as a fraction of ``size``.
    public let hotspot: CGPoint
    /// The cursor's size in the Mac's points (its shadow is in points).
    public let points: CGSize

    public init?(_ shape: ScreenCursorShape) {
        guard let image = shape.image() else { return nil }
        id = shape.id
        self.image = image
        size = CGSize(width: shape.w, height: shape.h)
        hotspot = CGPoint(x: shape.hx, y: shape.hy)
        points = CGSize(width: shape.pw, height: shape.ph)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.size == rhs.size && lhs.hotspot == rhs.hotspot && lhs.points == rhs.points
    }

    /// Where and how large to draw it on a picture `frame` pixels in size:
    /// the image's rectangle (its top left at the hotspot's offset from
    /// `pointer`), and frame pixels per Mac point (for the shadow).
    public func placement(at pointer: CGPoint, frame: CGSize) -> (rect: CGRect, pixelsPerPoint: CGFloat) {
        let width = size.width * frame.width
        let height = size.height * frame.height
        let origin = CGPoint(x: pointer.x - hotspot.x * width, y: pointer.y - hotspot.y * height)
        let pixelsPerPoint = points.width > 0 ? width / points.width : 1
        return (CGRect(origin: origin, size: CGSize(width: width, height: height)), pixelsPerPoint)
    }
}

/// The shapes a viewer has (more than the host remembers sending, so every
/// shape the host names without sending again is here) and the one the
/// telepointers name. A telepointer that names a shape not here yet keeps
/// the last one until it arrives: the cursor never flashes to another shape.
package struct ScreenStreamCursorCache {
    package static let capacity = 128
    private var shapes: [String: ScreenStreamCursor] = [:]
    private var order: [String] = []
    /// The shape the latest telepointers named.
    private var wanted: String?
    package private(set) var current: ScreenStreamCursor?

    package init() {}

    /// Adds a shape from the host; true when it becomes ``current``.
    package mutating func add(_ shape: ScreenStreamCursor) -> Bool {
        if shapes.updateValue(shape, forKey: shape.id) == nil {
            order.append(shape.id)
            if order.count > Self.capacity {
                let gone = order.removeFirst()
                shapes[gone] = nil
            }
        }
        guard shape.id == wanted, current != shape else { return false }
        current = shape
        return true
    }

    /// The telepointers named `id` (nil: a host that sends no shapes, no
    /// change); true when ``current`` changed.
    package mutating func select(_ id: String?) -> Bool {
        guard let id else { return false }
        wanted = id
        // Named again: newest, as the host's own memory has it.
        if let index = order.firstIndex(of: id), index != order.count - 1 {
            order.remove(at: index)
            order.append(id)
        }
        guard let shape = shapes[id], current != shape else { return false }
        current = shape
        return true
    }

    /// A new stream: its host's shapes start over.
    package mutating func reset() {
        self = Self()
    }
}
