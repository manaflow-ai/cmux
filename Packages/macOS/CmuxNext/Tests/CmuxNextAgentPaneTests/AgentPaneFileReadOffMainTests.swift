@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The agent pane's bundled files are read off the main actor: the body handed to
/// `WKURLSchemeTask.didReceive(_:)` on the main actor is bytes, not a mapping whose pages fault in
/// there (the same class as Leo's NIGHTLY hang 2026-11-16T21-27-58 in `PageSchemeHandler`). Base
/// red: ``AgentPaneSchemeHandler/read(_:)`` mapped the file, so an in-place write showed through.
struct AgentPaneFileReadOffMainTests {
    @Test func theReadBodyHoldsTheBytesReadNotAMappingOfTheFile() async throws {
        let size = 20 << 20
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "agent-pane-read-off-main-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "big.bin")
        try Data(repeating: 0x41, count: size).write(to: file)

        let body = try #require(await AgentPaneSchemeHandler.read(file))
        #expect(body.count == size)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0x42, count: size))
        try handle.synchronize()
        try handle.close()
        #expect(body == Data(repeating: 0x41, count: size),
                "the body changed with the file: it is a mapping, so its pages fault in on the main thread")
    }
}
