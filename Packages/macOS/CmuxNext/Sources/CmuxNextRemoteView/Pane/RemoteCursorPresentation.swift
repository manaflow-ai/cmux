package import CoreGraphics

/// Which cursor the pane shows (cap `cursor`: the host leaves its cursor out of the
/// pictures). One cursor that feels local: in Full Control, while the pointer is over the
/// picture and the remote cursor is where we put it, the local pointer wears the remote
/// shape and nothing is drawn over the video. The remote cursor is drawn (its shape, at its
/// position) only where it differs from the local pointer: View Only, the pointer outside
/// the picture, or the remote moving it on its own (an app warped it, another person).
package nonisolated struct RemoteCursorPresentation: Equatable, Sendable {
    package enum LocalCursor: Equatable, Sendable {
        /// The system arrow (no metadata, View Only, or the remote cursor is elsewhere).
        case system
        /// The remote cursor's shape, at the local pointer.
        case remoteShape
        /// Nothing: the remote hid its cursor.
        case hidden
    }

    package var local: LocalCursor
    package var drawsOverlay: Bool

    package static let none = RemoteCursorPresentation(local: .system, drawsOverlay: false)

    /// - Parameters:
    ///   - cursor: the latest remote cursor; nil until a host with the `cursor` cap sends one
    ///     (an older host keeps the cursor in its pictures: the system arrow, no overlay).
    ///   - control: Full Control (input goes to the host).
    ///   - pointerInImage: the local pointer is over the picture.
    ///   - echoesLocalPointer: the remote position is one this viewer sent (`RemotePointerEcho`).
    ///   - inFrame: the remote position is inside the stream (not on another display).
    package static func decide(cursor: RemoteCursorState?, control: Bool, pointerInImage: Bool,
                               echoesLocalPointer: Bool, inFrame: Bool) -> RemoteCursorPresentation {
        guard let cursor else { return .none }
        if control, pointerInImage, echoesLocalPointer {
            return RemoteCursorPresentation(local: cursor.visible ? .remoteShape : .hidden, drawsOverlay: false)
        }
        return RemoteCursorPresentation(local: .system, drawsOverlay: cursor.visible && inFrame)
    }
}

/// The pointer positions this viewer sent (stream pixels), to tell the host echoing our
/// own pointer from the remote moving its cursor on its own. A position the host reports
/// matches when it is within `tolerance` of the last one sent, or of one sent in the
/// last `window` (a remote that trails a fast move is still our pointer).
package nonisolated struct RemotePointerEcho: Sendable {
    /// Host rounding: points to pixels on both sides, at most a point at 2x plus one.
    package static let tolerance: Double = 3
    package static let window: Duration = .seconds(1)
    package static let capacity = 64

    private var sent: [(point: CGPoint, at: ContinuousClock.Instant)] = []

    package init() {}

    package var last: CGPoint? { sent.last?.point }

    package mutating func record(_ point: CGPoint, at now: ContinuousClock.Instant) {
        if let last = sent.last, last.point == point { return sent[sent.count - 1].at = now }
        sent.append((point, now))
        if sent.count > Self.capacity { sent.removeFirst(sent.count - Self.capacity) }
    }

    package func matches(_ position: CGPoint, at now: ContinuousClock.Instant) -> Bool {
        guard let last = sent.last else { return false }
        if Self.near(last.point, position) { return true }
        return sent.contains { now - $0.at <= Self.window && Self.near($0.point, position) }
    }

    private static func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }
}
