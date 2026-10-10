import Foundation

/// What the Downloads button shows: how many downloads the list holds and
/// whether one is still running (the button is then drawn active).
public nonisolated struct BrowserToolbarDownloads: Hashable, Sendable {
    public var count: Int
    public var inProgress: Bool

    public init(count: Int = 0, inProgress: Bool = false) {
        self.count = count
        self.inProgress = inProgress
    }
}
