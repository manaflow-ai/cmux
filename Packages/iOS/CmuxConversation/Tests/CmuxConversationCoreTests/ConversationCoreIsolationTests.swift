import Foundation
import Testing

/// CmuxConversationCore's main-actor state is reached only through code the
/// compiler checks. `MainActor.assumeIsolated` turns that check into a
/// runtime trap: if its closure ever runs off the main thread, the app
/// crashes (or, in a build without the check, races main-actor state).
/// Core is model code below the UI, so it has no call site that can only
/// prove the main thread at run time (finding strict-4: the short-time
/// cache's locale and time zone observers emptied the main-actor cache
/// through `assumeIsolated`, with no main-proof).
///
/// Reads the sources: a correct call today runs on the main thread, so no
/// runtime test can see the unchecked call.
@Suite struct ConversationCoreIsolationTests {
    @Test func coreHasNoAssumeIsolated() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxConversationCore")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var files: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" { files.append(file) }
        #expect(!files.isEmpty)
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
                if code.contains("assumeIsolated") { offenders.append("\(file.lastPathComponent):\(index + 1)") }
            }
        }
        #expect(offenders.isEmpty, "MainActor.assumeIsolated in CmuxConversationCore: \(offenders.sorted())")
    }
}
