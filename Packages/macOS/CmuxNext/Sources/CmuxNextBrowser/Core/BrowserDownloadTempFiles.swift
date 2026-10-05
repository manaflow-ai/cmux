public import Foundation

/// The record of the temporary `.cmuxdownload` files cmux writes. Not yet
/// implemented (red commit).
public final class BrowserDownloadTempFiles {
    public init(recordURL: URL) {}

    func add(_ url: URL) {}
    func remove(_ url: URL) {}

    /// Deletes the leftovers of an earlier run.
    public func cleanUpLeftovers() {}

    /// Returns when every record write so far has landed.
    func idle() async {}
}
