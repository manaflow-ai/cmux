import Foundation
import Testing

/// The macOS lab runner (`CmuxConversationLabMac`) reads its control FIFO on
/// a background thread and runs each command against AppKit and the lab's
/// main-actor state. `MainActor.assumeIsolated` only traps at run time when
/// the caller is off the main actor; the compiler checks nothing behind it.
/// The lab had four, none with a `// main-proof:` reason (strict-6): three
/// in top-level code, which Swift 6 already isolates to the main actor, and
/// one inside the reader thread's `DispatchQueue.main.sync`.
///
/// Each command now reaches the main actor through a `@MainActor` task, so
/// the compiler proves the isolation. A call that is still needed says why
/// its caller is on main with `// main-proof:` on its line or the line
/// above, as `scripts/cmux-next/crash_ratchet.py` asks.
///
/// The lab is an executable target that `swift test` cannot import, so this
/// reads its sources.
@Suite struct ConversationLabMacIsolationTests {
    @Test func labAssumesNoUnprovedMainActorIsolation() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxConversationLabMac")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("assumeIsolated") {
                let above = index > 0 ? lines[index - 1] : ""
                let proved = [line, above].contains { text in
                    guard let range = text.range(of: "// main-proof:") else { return false }
                    return !text[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
                }
                if !proved { offenders.append("\(file.lastPathComponent):\(index + 1)") }
            }
        }
        #expect(offenders.isEmpty, "MainActor.assumeIsolated without a main-proof in CmuxConversationLabMac: \(offenders.sorted())")
    }
}
