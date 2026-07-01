public import Foundation

/// Decides whether a terminal open-URL target may be handled by cmux's file UI.
public struct TerminalOpenURLFileRoutingPolicy: Sendable {
    /// Creates the file-routing policy.
    public init() {}

    /// Returns whether cmux may attempt to open the target in its file preview UI.
    ///
    /// The caller still owns settings, file existence, workspace locality, and
    /// split creation checks. This policy only answers whether the raw terminal
    /// open-URL payload represents a local file shape that cmux is allowed to
    /// intercept before the normal URL routing decision.
    ///
    /// - Parameters:
    ///   - rawOpenURLValue: The raw open-URL payload from the terminal runtime.
    ///   - target: The parsed terminal link target.
    public func shouldAttemptCmuxFileRouting(
        rawOpenURLValue _: String,
        target: TerminalOpenURLTarget
    ) -> Bool {
        guard target.url.isFileURL else { return false }
        return Self.isLocalFileURL(target.url)
    }

    private static func isLocalFileURL(_ url: URL) -> Bool {
        let host = url.host
        return host == nil || host?.isEmpty == true || host == "localhost"
    }
}
