public import CmuxFoundation
import Foundation

/// Reads live Git changes through an injected subprocess seam.
///
/// The actor performs repository I/O away from UI isolation and exposes only
/// immutable, `Sendable` response values. Tests can inject any
/// ``CmuxFoundation/CommandRunning`` implementation.
public actor ChangesEngine {
    static let emptyTreeHash = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    static let largeLineThreshold = 3_000
    static let largePatchByteThreshold = 1_048_576
    static let maximumSummaryFiles = 5_000
    static let pageRowLimit = 4_000

    let commandRunner: any CommandRunning

    /// Creates a changes engine.
    /// - Parameter commandRunner: The subprocess runner used for every `/usr/bin/git` invocation.
    public init(commandRunner: any CommandRunning = CommandRunner()) {
        self.commandRunner = commandRunner
    }
}
