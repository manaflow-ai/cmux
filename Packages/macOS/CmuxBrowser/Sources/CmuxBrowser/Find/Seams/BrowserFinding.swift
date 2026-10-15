import Foundation

/// The find-in-page operations a browser panel's find bar drives, independent of the engine.
///
/// WebKit pages answer through ``BrowserFindService`` (find scripts evaluated in the page);
/// Chromium pages answer through ``BrowserNativeFindSession`` (the engine's own find, which
/// highlights matches and reports counts natively). The panel keeps one conformer per page and
/// never needs to know which engine renders it.
@MainActor
public protocol BrowserFinding: AnyObject {
    /// Searches for `needle` and returns the resulting match count.
    /// - Parameter needle: The text to search for. An empty needle is not searched and returns `nil`.
    /// - Returns: The match count, or `nil` when the search could not run.
    func search(needle: String) async -> BrowserFindMatchCount?

    /// Moves to the next match of the current needle.
    /// - Returns: The match count after moving, or `nil` when nothing is being searched.
    func next() async -> BrowserFindMatchCount?

    /// Moves to the previous match of the current needle.
    /// - Returns: The match count after moving, or `nil` when nothing is being searched.
    func previous() async -> BrowserFindMatchCount?

    /// Removes every find highlight from the page.
    func clear() async
}
