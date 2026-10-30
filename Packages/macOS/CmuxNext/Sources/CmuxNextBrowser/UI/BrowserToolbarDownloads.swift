import Foundation

/// What the Downloads button shows: how many downloads the list holds,
/// whether one is still running (the button is then drawn active), and how
/// far the running ones are (its progress ring).
public nonisolated struct BrowserToolbarDownloads: Hashable, Sendable {
    public var count: Int
    public var inProgress: Bool
    /// The running downloads' bytes so far over their total, in whole
    /// percent steps (0...1); nil while one has no known size (the ring then
    /// shows a short arc) or none runs.
    public var progress: Double?

    public init(count: Int = 0, inProgress: Bool = false, progress: Double? = nil) {
        self.count = count
        self.inProgress = inProgress
        self.progress = progress
    }
}
