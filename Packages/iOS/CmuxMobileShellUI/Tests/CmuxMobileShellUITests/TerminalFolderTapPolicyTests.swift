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

        let decision = await TerminalFolderTapPolicy.decision(
            for: "/tmp/folder",
            folderTapEnabled: true,
            stat: { path in await stub.stat(path: path) }
        )

        let invocationCount = await stub.invocationCount
        #expect(decision == .openArtifact)
        #expect(invocationCount == 0)
    }

    @Test("disabled lets directory taps fall through to the terminal")
    func disabledDirectoryFocusesTerminal() async {
        let decision = await TerminalFolderTapPolicy.decision(
            for: "/tmp/folder",
            folderTapEnabled: false,
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
        let decision = await TerminalFolderTapPolicy.decision(
            for: "/tmp/file",
            folderTapEnabled: false,
            stat: { _ in kind }
        )

        #expect(decision == .openArtifact)
    }

    @Test("disabled fails open when stat throws")
    func disabledStatFailureOpensArtifact() async {
        let decision = await TerminalFolderTapPolicy.decision(
            for: "/tmp/file",
            folderTapEnabled: false,
            stat: { _ in throw StatFailure() }
        )

        #expect(decision == .openArtifact)
    }
}
