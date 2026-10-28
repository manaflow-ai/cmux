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
/// stability plan keeps `@preconcurrency` to the Sparkle seam only, so no
/// source of this package has one.
@Suite struct MacUIPreconcurrencyTests {
    @Test func conversationSourcesHaveNoPreconcurrencyEscape() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.contains { $0.lastPathComponent == "MacEmojiInputView.swift" })
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
                let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
                if code.contains("@preconcurrency") {
                    offenders.append("\(file.deletingLastPathComponent().lastPathComponent)/\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "@preconcurrency in CmuxConversation sources: \(offenders.sorted())")
    }
}
