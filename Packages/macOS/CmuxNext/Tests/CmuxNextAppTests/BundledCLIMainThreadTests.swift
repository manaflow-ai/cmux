@testable import CmuxNextApp
@testable import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing

/// The bundled `cmux` that TopPages (Automations), PageFactory (agent integrations), ChiefMoveHandlers and the
/// server source ask for: they ask on the main thread, at registration or in a menu's availability check, so
/// asking makes no file system call there. Whether the binary is there is read once on the files lane and kept.
@Suite
struct BundledCLIMainThreadTests {
    #if DEBUG
    @MainActor @Test func askingForTheBundledCLIOnTheMainThreadTouchesNoFile() async {
        let resources = Self.resources(withCLI: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        let table = BlockingViolationTable(mode: .record)
        let (known, resolved) = await BlockingViolationTable.$scoped.withValue(table) {
            let cli = BundledExecutable(resources: resources, name: "cmux", work: BackgroundWork())
            return (cli.known, await cli.resolve())
        }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty)
        #expect(known?.path == resources.appendingPathComponent("bin/cmux").path)
        #expect(resolved?.path == resources.appendingPathComponent("bin/cmux").path)
    }
    #endif

    /// A build without the binary answers nil once the read is done, and keeps that answer.
    @MainActor @Test func aBuildWithoutTheCLIAnswersNilAndKeepsIt() async {
        let resources = Self.resources(withCLI: false)
        defer { try? FileManager.default.removeItem(at: resources) }
        let cli = BundledExecutable(resources: resources, name: "cmux", work: BackgroundWork())
        #expect(cli.known != nil, "before the first read, the candidate")
        #expect(await cli.resolve() == nil)
        #expect(cli.known == nil)
        #expect(BundledExecutable(resources: nil, name: "cmux", work: BackgroundWork()).known == nil)
    }

    private static func resources(withCLI: Bool) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-cli-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        if withCLI {
            let binary = bin.appendingPathComponent("cmux")
            try? Data("#!/bin/sh\n".utf8).write(to: binary)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        }
        return root
    }
}
