import Foundation

/// The small built-in wordmark used by the empty-workspace splash.
///
/// Keep this as plain text so it stays crisp in the terminal-style face and can
/// become the first entry in the future `cmux art` gallery without changing the
/// splash layout. The slant wordmark was the clear winner of the light/dark
/// pairwise vote recorded on #15245.
enum EmptyWorkspaceArt {
    static let wordmark = """
     ___ _ __ ___  _   ___
    / __| '_ ` _ \\| | | \\
    \\__ \\ | \\ | | |_| |
    |___/_| |_| |_|\\__,_|
    """
}
