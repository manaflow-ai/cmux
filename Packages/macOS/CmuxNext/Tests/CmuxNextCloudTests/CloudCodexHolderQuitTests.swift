@testable import CmuxNextCloud
import Foundation
import Testing

/// A quit detaches a running Codex holder and never starts one: the detach used to start a holder
/// only to tell it to detach, and a quit seconds after launch waited on that start to the quit's
/// deadline (going back to the previous build took 3.8 s longer, update harness 2026-11-11).
@MainActor @Suite(.timeLimit(.minutes(1)))
struct CloudCodexHolderQuitTests {
    @Test func aQuitWithNoHolderRunningStartsNone() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-holder-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A holder that notes each start, then reads its lines until stdin closes.
        let script = folder.appendingPathComponent("holder")
        try Data("""
        #!/bin/sh
        echo started >> '\(folder.path)/starts'
        cat > /dev/null
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let holder = CloudCodexHolder(
            configuration: .init(binary: script, root: folder, userHome: folder, api: URL(string: "https://example.invalid")!,
                                 cacheDirectory: nil, appVersion: "test"),
            answers: .init(credential: { nil }, acpmux: { nil }, currentScope: { nil },
                           ownsMachine: { _ in false }, isLive: { _ in false }))

        let started = ContinuousClock.now
        await holder.detachForQuit()
        #expect(ContinuousClock.now - started < .seconds(1), "the quit does not wait on a holder")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("starts").path),
                "a quit starts no holder")
    }
}
