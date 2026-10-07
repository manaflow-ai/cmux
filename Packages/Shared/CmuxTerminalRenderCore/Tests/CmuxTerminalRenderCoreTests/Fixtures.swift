import Foundation

/// Paths of the repository fixtures this package's tests read.
struct Fixtures {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let schemas = repository.appendingPathComponent("schemas/terminal-corpus")
    /// The benchmark screen's bundled copies.
    static let bundled = repository.appendingPathComponent("ios/CmuxiOS/Sources/CmuxiOSTerminal/Resources/TerminalCorpus")
}
