#if os(iOS)
import CoreGraphics

/// Which row the frame-shift measures follow from one committed frame to the next, and how far it
/// moved (DEBUG measure only; the app never sets a probe). `previous` and `current` are the rows on
/// screen in each frame, in screen order, each with its place in the window (top, or bottom for an
/// `.up` list at its newest row); `reading` is the row read in the previous frame.
enum PagedListFollow {
    struct Row<ID: Hashable> {
        var id: ID
        var y: CGFloat
    }

    /// The row followed and its place in both frames; nil when no row can be followed.
    static func pick<ID: Hashable>(previous: [Row<ID>], current: [Row<ID>], reading: ID?) -> (id: ID, was: CGFloat, now: CGFloat)? {
        // The row being read, by its id, wherever it is now; else the first row in both frames.
        if let reading, let was = previous.first(where: { $0.id == reading }), let now = current.first(where: { $0.id == reading }) {
            return (reading, was.y, now.y)
        }
        for was in previous {
            if let now = current.first(where: { $0.id == was.id }) { return (was.id, was.y, now.y) }
        }
        return nil
    }
}
#endif
