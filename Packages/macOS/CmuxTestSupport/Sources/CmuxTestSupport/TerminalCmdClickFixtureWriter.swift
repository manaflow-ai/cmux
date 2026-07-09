#if DEBUG
public import Foundation

/// Seeds the on-disk fixture files for the terminal cmd-click XCUITest scenario.
///
/// `TerminalCmdClickUITestRecorder` (app target) resolves the fixture directory,
/// the expected/sibling file URLs, and the optional extra file names from the
/// scenario environment, then constructs one writer and calls ``seed()`` once the
/// terminal surface is ready. The seeding work is pure `FileManager`/`URL`/`String`
/// I/O with no AppKit, Ghostty, or live-state coupling, so it lives here as a
/// value type; the app keeps the surrounding `do`/`catch` that turns a thrown
/// error into the recorder's `"Failed to create fixture"` setup-error state.
///
/// ``seed()`` reproduces the legacy inline `AppDelegate` block byte-for-byte: it
/// creates the fixture directory and the expected file's parent directory, writes
/// `"fixture\n"` to the expected and sibling files only when they do not already
/// exist, then for each non-empty extra file name creates its parent directory
/// and writes `"fixture\n"` when absent, in the original order.
public struct TerminalCmdClickFixtureWriter: Sendable {
    /// The fixture directory created (with intermediates) before seeding files.
    public let fixtureDirectory: URL
    /// The expected fixture file URL written with `"fixture\n"` when absent.
    public let expectedFile: URL
    /// The sibling fixture file URL written with `"fixture\n"` when absent.
    public let siblingFile: URL
    /// The optional extra fixture file names, each resolved against the fixture
    /// directory and written with `"fixture\n"` when absent.
    public let extraFileNames: [String]

    /// Creates a writer for the resolved fixture URLs and extra file names.
    ///
    /// - Parameters:
    ///   - fixtureDirectory: The fixture directory to create before seeding.
    ///   - expectedFile: The expected fixture file URL.
    ///   - siblingFile: The sibling fixture file URL.
    ///   - extraFileNames: Extra fixture file names relative to the fixture
    ///     directory; empty names are skipped.
    public init(
        fixtureDirectory: URL,
        expectedFile: URL,
        siblingFile: URL,
        extraFileNames: [String]
    ) {
        self.fixtureDirectory = fixtureDirectory
        self.expectedFile = expectedFile
        self.siblingFile = siblingFile
        self.extraFileNames = extraFileNames
    }

    /// Creates the fixture directories and seeds the fixture/sibling/extra files,
    /// throwing the first `FileManager`/write error encountered.
    public func seed() throws {
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: expectedFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: expectedFile.path) {
            try "fixture\n".write(to: expectedFile, atomically: true, encoding: .utf8)
        }
        if !FileManager.default.fileExists(atPath: siblingFile.path) {
            try "fixture\n".write(to: siblingFile, atomically: true, encoding: .utf8)
        }
        for extraFileName in extraFileNames where !extraFileName.isEmpty {
            let extraFileURL = fixtureDirectory.appendingPathComponent(extraFileName)
            try FileManager.default.createDirectory(
                at: extraFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: extraFileURL.path) {
                try "fixture\n".write(to: extraFileURL, atomically: true, encoding: .utf8)
            }
        }
    }
}
#endif
