import Foundation
import Testing

/// #23821's probe: a launch crash read a stored property of a live object that held a libmalloc
/// free-list word while a background thread dlopened the CEF framework, whose PartitionAlloc
/// constructor swaps the default malloc zone. This runs scripts/cmux-next/malloc-zone-race/run.sh
/// corrupt (a C program that does what cmux-next's launch does, under libmalloc's heap checks) and
/// expects every run clean. It needs the CEF framework: a fleet step with `cmux-ci run --cef
/// sha256:<cef-manifest.json sha256>` sets CMUX_CI_CEF_DIR; without it the test does nothing.
@Suite
struct MallocZoneSwapProbeTests {
    private static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func framework(under root: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "Chromium Embedded Framework", url.deletingLastPathComponent().pathExtension == "framework" {
                return url
            }
        }
        return nil
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_CI_CEF_DIR"] != nil, "needs CMUX_CI_CEF_DIR (cmux-ci run --cef)"),
          .timeLimit(.minutes(20)))
    func theZoneSwapDuringABackgroundDlopenLeavesLiveBlocksIntact() throws {
        let dist = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CMUX_CI_CEF_DIR"]))
        let binary = try #require(Self.framework(under: dist), "no Chromium Embedded Framework under \(dist.path)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repository.appending(path: "scripts/cmux-next/malloc-zone-race/run.sh").path,
                             "corrupt", "40", binary.path, "1"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        print(text)
        #expect(process.terminationStatus == 0, "\(text)")
    }
}
