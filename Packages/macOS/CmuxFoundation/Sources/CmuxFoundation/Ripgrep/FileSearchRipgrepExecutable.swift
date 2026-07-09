public import Foundation

/// A resolved `rg` (ripgrep) executable plus any fixed arguments that must
/// precede the caller's own arguments when launching it.
///
/// `prefixArguments` exists so a resolver can front-load flags required by the
/// way the binary was found (currently always empty for a directly-resolved
/// `rg`); callers append their own search arguments after it.
public struct FileSearchRipgrepExecutable: Equatable, Sendable {
    /// Filesystem URL of the `rg` executable to launch.
    public let url: URL
    /// Arguments to pass before the caller's own arguments.
    public let prefixArguments: [String]

    /// - Parameters:
    ///   - url: filesystem URL of the `rg` executable.
    ///   - prefixArguments: arguments to pass before the caller's arguments.
    public init(url: URL, prefixArguments: [String]) {
        self.url = url
        self.prefixArguments = prefixArguments
    }
}
