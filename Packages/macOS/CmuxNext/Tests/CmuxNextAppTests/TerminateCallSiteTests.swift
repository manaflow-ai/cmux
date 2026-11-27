import Foundation
import Testing

/// Detector for the quit deadlock's class: `NSApp.terminate` called inside a main-queue job (a
/// main-actor Task, a `DispatchQueue.main` block) never quits a terminateLater quit, because the
/// quit's reply needs the main queue that job holds (a relaunch, keep sessions, hung a NIGHTLY that
/// way). Every quit asks through `NSApplication.terminateFromRunLoop`, which calls terminate from a
/// run-loop callout; this test keeps it the only caller.
struct TerminateCallSiteTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources", isDirectory: true)
    private static let helper = "CmuxNextCompat/NSApplication+TerminateFromRunLoop.swift"

    @Test func onlyTerminateFromRunLoopCallsNSAppTerminate() throws {
        let pattern = try Regex(#"(NSApp|NSApplication\.shared)[?!]?\.terminate\("#)
        let files = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var hits: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            let relative = String(url.standardizedFileURL.path.dropFirst(Self.sources.standardizedFileURL.path.count + 1))
            guard relative != Self.helper else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.drop { $0 == " " }
                guard !code.hasPrefix("//"), line.contains(pattern) else { continue }
                hits.append("\(relative):\(index + 1): \(code)")
            }
        }
        #expect(scanned > 100, "found no sources at \(Self.sources.path)")
        #expect(hits.isEmpty, "call NSApplication.terminateFromRunLoop() instead (a terminate inside a main-queue job deadlocks a terminateLater quit):\n\(hits.joined(separator: "\n"))")
    }
}
