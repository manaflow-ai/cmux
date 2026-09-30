import CoreGraphics

/// How the next tab a window request sent to a window opens: its
/// disposition and, for a popup, the window features the page gave.
nonisolated struct CEFPlacement: Equatable, Sendable {
    var disposition: BrowserNewTabDisposition
    var bounds: CGRect?

    /// The popup features to use: the window request's bounds, else the
    /// features Chromium reported at creation.
    static func resolvedBounds(request: CGRect?, created: CGRect?) -> CGRect? {
        request ?? created
    }
}

/// Placements by Chromium window id, oldest first.
nonisolated struct CEFPlacementQueue: Equatable, Sendable {
    private var queues: [Int32: [CEFPlacement]] = [:]

    mutating func record(window: Int32, _ placement: CEFPlacement) {
        queues[window, default: []].append(placement)
    }

    mutating func take(window: Int32) -> CEFPlacement? {
        guard var queue = queues[window], !queue.isEmpty else { return nil }
        let first = queue.removeFirst()
        queues[window] = queue.isEmpty ? nil : queue
        return first
    }
}
