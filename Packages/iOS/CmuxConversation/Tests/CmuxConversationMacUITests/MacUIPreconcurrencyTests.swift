import Foundation
import Testing

/// A `@preconcurrency` conformance switches off the compiler's isolation
/// check for every requirement of the protocol: a main-actor view's methods
/// may then satisfy a nonisolated protocol, and nothing checks that the
/// conformance is only used on the main thread. The Mac emoji input conformed
/// to `NSTextInputClient` that way with no written reason (finding
/// strict-13).
///
/// A main-actor type that adopts a nonisolated AppKit protocol states that
/// with an isolated conformance (`@MainActor NSTextInputClient`, as
/// `RemoteInputCaptureView` does), which the compiler checks. The cmux-next
/// stability plan keeps `@preconcurrency` to the Sparkle seam only, so this
/// module has none.
@Suite struct MacUIPreconcurrencyTests {
    @Test func macUIHasNoPreconcurrencyEscape() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxConversationMacUI")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
                if code.contains("@preconcurrency") { offenders.append("\(file.lastPathComponent):\(index + 1)") }
            }
        }
        #expect(offenders.isEmpty, "@preconcurrency in CmuxConversationMacUI: \(offenders.sorted())")
    }
}
