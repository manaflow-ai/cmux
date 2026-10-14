import Testing

@testable import CmuxBrowser

/// A text input client whose focus can move while the commit waits for the
/// editor state, as a page can move focus during that wait.
@MainActor
private final class FakeTextTarget: BrowserReplTextCommitTarget {
    var focusedOrigin = "https://allowed.example"
    var originAfterPreparation: String?
    var richText = true
    var hasMarkedText = false
    private(set) var log: [String] = []

    func prepareComposition() async -> Bool {
        log.append("prepare")
        if let originAfterPreparation { focusedOrigin = originAfterPreparation }
        return richText
    }

    func setMarkedText(_ text: String) { log.append("marked \(focusedOrigin) \(text)") }

    func insertText(_ text: String) { log.append("insert \(focusedOrigin) \(text)") }
}

private struct Refused: Error, Equatable {
    let origin: String
}

@MainActor
@Suite("Browser REPL text commit")
struct BrowserReplTextCommitTests {
    private func allowOnly(_ target: FakeTextTarget) -> @MainActor () async throws -> Void {
        {
            guard target.focusedOrigin == "https://allowed.example" else {
                throw Refused(origin: target.focusedOrigin)
            }
        }
    }

    @Test func aRichTextEditorGetsMarkedTextThenTheInsert() async throws {
        let target = FakeTextTarget()
        try await target.commit("pw", checkTarget: allowOnly(target))
        #expect(target.log == ["prepare", "marked https://allowed.example pw", "insert https://allowed.example pw"])
    }

    @Test func aLineBreakIsInsertedWithoutAComposition() async throws {
        let target = FakeTextTarget()
        try await target.commit("a\nb", checkTarget: allowOnly(target))
        #expect(target.log == ["insert https://allowed.example a\nb"])
    }

    @Test func focusThatMovesWhileTheEditorStateSettlesIsRefused() async throws {
        // The target passes the check when the call starts; the page moves
        // focus to another origin's frame while the commit waits for the
        // editor state. The check must see the element that receives the text.
        let target = FakeTextTarget()
        target.originAfterPreparation = "https://evil.example"
        await #expect(throws: Refused(origin: "https://evil.example")) {
            try await target.commit("pw", checkTarget: allowOnly(target))
        }
        #expect(!target.log.contains { $0.hasPrefix("insert") || $0.hasPrefix("marked") })
    }

    @Test func aRefusedTargetGetsNothing() async throws {
        let target = FakeTextTarget()
        target.focusedOrigin = "https://evil.example"
        target.richText = false
        await #expect(throws: Refused(origin: "https://evil.example")) {
            try await target.commit("pw", checkTarget: allowOnly(target))
        }
        #expect(!target.log.contains { $0.hasPrefix("insert") || $0.hasPrefix("marked") })
    }
}
