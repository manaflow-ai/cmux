/// Incremental pane-output cursor (tmux ``%output`` analogue for ``pane.read``).
public struct RemoteHerdrOutputCursor: Hashable, Sendable {
    /// Last fully painted snapshot.
    public var previous: String

    /// Creates an empty cursor.
    public init(previous: String = "") {
        self.previous = previous
    }
}

/// Diff of one pane-read snapshot against the last painted text.
public struct RemoteHerdrOutputDelta: Hashable, Sendable {
    /// Bytes (UTF-8 text) to write.
    public var chunk: String
    /// Whether the host must clear and repaint instead of appending.
    public var fullRedraw: Bool

    /// Creates an output delta.
    public init(chunk: String, fullRedraw: Bool) {
        self.chunk = chunk
        self.fullRedraw = fullRedraw
    }
}

/// Computes incremental output for a mirrored pane.
public enum RemoteHerdrOutput {
    /// Returns the suffix when ``current`` extends ``previous``; otherwise a redraw.
    public static func delta(
        previous: String?,
        current: String
    ) -> (RemoteHerdrOutputDelta, RemoteHerdrOutputCursor) {
        guard let previous else {
            return (
                RemoteHerdrOutputDelta(chunk: current, fullRedraw: true),
                RemoteHerdrOutputCursor(previous: current)
            )
        }
        if current == previous {
            return (
                RemoteHerdrOutputDelta(chunk: "", fullRedraw: false),
                RemoteHerdrOutputCursor(previous: current)
            )
        }
        if current.hasPrefix(previous) {
            let start = current.index(current.startIndex, offsetBy: previous.count)
            return (
                RemoteHerdrOutputDelta(chunk: String(current[start...]), fullRedraw: false),
                RemoteHerdrOutputCursor(previous: current)
            )
        }
        return (
            RemoteHerdrOutputDelta(chunk: current, fullRedraw: true),
            RemoteHerdrOutputCursor(previous: current)
        )
    }
}
