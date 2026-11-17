@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The agent pane's bundled files are read off the main actor: the body handed to
/// `WKURLSchemeTask.didReceive(_:)` on the main actor is bytes, not a mapping whose pages fault in
/// there (the same class as the NIGHTLY hang 2026-11-16T21-27-58 in `PageSchemeHandler`). Base
/// red: ``AgentPaneSchemeHandler/read(_:)`` mapped the file, so an in-place write showed through.
struct AgentPaneFileReadOffMainTests {
    static let size = 20 << 20

    @Test func theReadBodyHoldsTheBytesReadNotAMappingOfTheFile() async throws {
        let dir = try Self.mappableDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "big.bin")
        try Data(repeating: 0x41, count: Self.size).write(to: file)

        let body = try #require(await AgentPaneSchemeHandler.read(file))
        #expect(body.count == Self.size)

        try Self.overwriteInPlace(file, with: 0x42)
        #expect(body == Data(repeating: 0x41, count: Self.size),
                "the body changed with the file: it is a mapping, so its pages fault in on the main thread")
    }

    /// A new directory where `.mappedIfSafe` really maps (as for the app bundle on the boot disk),
    /// proven by a control read; a CI worker's `TMPDIR` may sit on a volume where it never maps.
    static func mappableDirectory() throws -> URL {
        let candidates = [URL(fileURLWithPath: "/private/tmp", isDirectory: true),
                          FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches", directoryHint: .isDirectory),
                          FileManager.default.temporaryDirectory]
        for base in candidates {
            let dir = base.appending(path: "agent-pane-read-off-main-\(UUID().uuidString)", directoryHint: .isDirectory)
            guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { continue }
            let probe = dir.appending(path: "probe.bin")
            let shows: Bool = (try? {
                try Data(repeating: 0x41, count: size).write(to: probe)
                let mapped = try Data(contentsOf: probe, options: .mappedIfSafe)
                try overwriteInPlace(probe, with: 0x42)
                return mapped.last == 0x42
            }()) ?? false
            try? FileManager.default.removeItem(at: probe)
            if shows { return dir }
            try? FileManager.default.removeItem(at: dir)
        }
        Issue.record("no candidate directory shows a .mappedIfSafe mapping: the oracle cannot tell a read from a map here")
        throw CocoaError(.fileReadUnknown)
    }

    static func overwriteInPlace(_ file: URL, with byte: UInt8) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: byte, count: size))
        try handle.synchronize()
    }
}
