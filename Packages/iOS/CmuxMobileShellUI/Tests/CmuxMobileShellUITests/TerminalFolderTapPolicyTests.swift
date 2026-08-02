import CmuxAgentChat
import Testing

@testable import CmuxMobileShellUI

@Suite("Terminal folder tap policy")
struct TerminalFolderTapPolicyTests {
    private actor CountingStatStub {
        let kind: ChatArtifactKind
        private(set) var invocationCount = 0

        init(kind: ChatArtifactKind) {
            self.kind = kind
        }

        func stat(path: String) -> ChatArtifactKind {
            invocationCount += 1
            return kind
        }
    }

    private struct StatFailure: Error {}

    @Test("enabled opens without statting")
    func enabledOpensWithoutStatting() async {
        let stub = CountingStatStub(kind: .directory)

        let decision = await TerminalFolderTapPolicy(folderTapEnabled: true).decision(
            for: "/tmp/folder",
            stat: { path in await stub.stat(path: path) }
        )

        let invocationCount = await stub.invocationCount
        #expect(decision == .openArtifact)
        #expect(invocationCount == 0)
    }

    @Test("disabled lets directory taps fall through to the terminal")
    func disabledDirectoryFocusesTerminal() async {
        let decision = await TerminalFolderTapPolicy(folderTapEnabled: false).decision(
            for: "/tmp/folder",
            stat: { _ in .directory }
        )

        #expect(decision == .focusTerminal)
    }

    @Test("disabled still opens non-directory artifacts", arguments: [
        ChatArtifactKind.image,
        .text,
        .binary,
    ])
    func disabledNonDirectoryOpensArtifact(kind: ChatArtifactKind) async {
        let decision = await TerminalFolderTapPolicy(folderTapEnabled: false).decision(
            for: "/tmp/file",
            stat: { _ in kind }
        )

        #expect(decision == .openArtifact)
    }

    @Test("disabled lets the artifact viewer handle forbidden paths")
    func disabledForbiddenPathOpensArtifact() async {
        let decision = await TerminalFolderTapPolicy(folderTapEnabled: false).decision(
            for: "data.csv",
            stat: { _ in throw ChatArtifactError.forbidden }
        )

        #expect(decision == .openArtifact)
    }

    @Test("disabled fails closed when stat throws")
    func disabledStatFailureFocusesTerminal() async {
        let decision = await TerminalFolderTapPolicy(folderTapEnabled: false).decision(
            for: "/tmp/file",
            stat: { _ in throw StatFailure() }
        )

        #expect(decision == .focusTerminal)
    }

    @Test("disabled fails closed when classification exceeds its deadline")
    func disabledClassificationDeadlineFocusesTerminal() async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let decision = await TerminalFolderTapPolicy(
            folderTapEnabled: false,
            classificationDeadline: .milliseconds(50)
        ).decision(
            for: "/tmp/file",
            stat: { _ in
                await withCheckedContinuation { continuation in
                    _ = Task.detached {
                        try? await Task.sleep(for: .seconds(2))
                        continuation.resume()
                    }
                }
                return .text
            }
        )
        let elapsed = startedAt.duration(to: clock.now)

        #expect(decision == .focusTerminal)
        #expect(elapsed < .seconds(1), "Deadline result took \(elapsed)")
    }

    @Test("disabled still accepts a fast classification before the deadline")
    func disabledFastClassificationOpensArtifact() async {
        let decision = await TerminalFolderTapPolicy(
            folderTapEnabled: false,
            classificationDeadline: .milliseconds(50)
        ).decision(
            for: "/tmp/file",
            stat: { _ in .text }
        )

        #expect(decision == .openArtifact)
    }
}
