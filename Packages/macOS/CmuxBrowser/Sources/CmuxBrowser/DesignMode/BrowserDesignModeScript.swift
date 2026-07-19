import Foundation

/// Loads the isolated JavaScript runtime shipped with ``CmuxBrowser``.
public struct BrowserDesignModeScript: Sendable {
    /// Creates a runtime script loader.
    public init() {}

    /// Loads the bundled runtime source.
    /// - Returns: The JavaScript source to evaluate in an isolated WebKit content world.
    /// - Throws: A Cocoa file error when the resource cannot be found or decoded.
    @concurrent
    public func source() async throws -> String {
        guard let url = Bundle.module.url(forResource: "BrowserDesignModeRuntime", withExtension: "js") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
