import AppKit

/// The panes stacked above each pane host of a screen (``ScreenContentView/panesAbove()``), kept
/// from the last walk while every host's frame, visibility and stacking order are as they were.
///
/// The walk compares each host with every opaque host in front of it, O(n²) in the hosts; a
/// motion frame asks for it twice (the presentation pass and the overlay sync) and a frame at rest
/// asks again. The memo makes the repeats one O(n) compare of the hosts' inputs.
struct PanesAboveMemo {
    /// One host's inputs to the walk, in front-to-back order.
    private struct Entry: Equatable {
        let host: ObjectIdentifier
        let frame: CGRect
        /// Shown and fully opaque: it covers what is behind it.
        let covers: Bool
    }

    private var entries: [Entry] = []
    private var result: [ObjectIdentifier: [CGRect]] = [:]
    /// Walks run, cumulative (tests: a second ask with nothing changed walks nothing).
    private(set) var walks = 0

    /// For each of `hosts` (front to back), the frames of the opaque hosts in front of it that
    /// overlap it, back to front; hosts nothing overlaps are absent.
    mutating func covers(frontToBack hosts: [PaneHostView]) -> [ObjectIdentifier: [CGRect]] {
        let entries = hosts.map { Entry(host: ObjectIdentifier($0), frame: $0.frame, covers: !$0.isHidden && $0.alphaValue > 0.99) }
        self.entries = entries
        walks += 1
        var covers: [ObjectIdentifier: [CGRect]] = [:]
        var front: [CGRect] = []
        for entry in entries {
            let overlapping = front.filter {
                let shared = $0.intersection(entry.frame)
                return shared.width > 0.5 && shared.height > 0.5
            }
            if !overlapping.isEmpty { covers[entry.host] = overlapping.reversed() }
            if entry.covers { front.append(entry.frame) }
        }
        result = covers
        return covers
    }
}
