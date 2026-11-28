import CCmuxScreenKit
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
        let placement = cmux_screen_cursor_placement(geometry, CmuxScreenPoint(pointer), CmuxScreenSize(frame))
        return (CGRect(placement.rect), placement.pixels_per_point)
    }

    var geometry: CmuxScreenCursorGeometry {
        CmuxScreenCursorGeometry(size: CmuxScreenSize(size), hotspot: CmuxScreenPoint(hotspot), points: CmuxScreenSize(points))
    }
}

/// The shapes a viewer has (more than the host remembers sending, so every
/// shape the host names without sending again is here) and the one the
/// telepointers name. A telepointer that names a shape not here yet keeps
/// the last one until it arrives: the cursor never flashes to another shape.
/// The cache's rules are cmux-rd-core `screen_kit::cursor`; this keeps the
/// images and drops the one it evicts.
package struct ScreenStreamCursorCache {
    package static let capacity = 128
    private let handle = ScreenKitHandle(cmux_screen_cursor_cache_new(), free: cmux_screen_cursor_cache_free)
    private var images: [String: ScreenStreamCursor] = [:]
    /// The longest id added: an evicted id fits in this many bytes.
    private var longestID = 64
    package private(set) var current: ScreenStreamCursor?

    package init() {}

    /// Adds a shape from the host; true when it becomes ``current``.
    package mutating func add(_ shape: ScreenStreamCursor) -> Bool {
        var id = shape.id
        longestID = max(longestID, id.utf8.count)
        images[id] = shape
        var becameCurrent = false
        let evicted: String? = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: longestID) { buffer in
            var length = 0
            let status = id.withUTF8 { bytes in
                cmux_screen_cursor_cache_add(handle.raw, bytes.baseAddress, bytes.count, shape.geometry,
                                             &becameCurrent, buffer.baseAddress, buffer.count, &length)
            }
            guard status == CMUX_SCREEN_OK, length > 0 else { return nil }
            return String(decoding: buffer.prefix(length), as: UTF8.self)
        }
        if let evicted { images[evicted] = nil }
        guard becameCurrent else { return false }
        current = shape
        return true
    }

    /// The telepointers named `id` (nil: a host that sends no shapes, no
    /// change); true when ``current`` changed.
    package mutating func select(_ id: String?) -> Bool {
        guard var id else { return false }
        var changed = false
        id.withUTF8 { bytes in
            if let base = bytes.baseAddress {
                _ = cmux_screen_cursor_cache_select(handle.raw, base, bytes.count, &changed)
            } else {
                // The empty id still names a shape; NULL would mean no change.
                let empty: UInt8 = 0
                withUnsafePointer(to: empty) { _ = cmux_screen_cursor_cache_select(handle.raw, $0, 0, &changed) }
            }
        }
        guard changed, let shape = images[id] else { return false }
        current = shape
        return true
    }

    /// A new stream: its host's shapes start over.
    package mutating func reset() {
        cmux_screen_cursor_cache_reset(handle.raw)
        images = [:]
        current = nil
    }
}
