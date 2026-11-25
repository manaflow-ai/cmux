@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextFiles
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// A Markdown runbook's Run buttons (webviews `pages/markdown/runbook.ts`): `runBlock` sends a
/// shell block's command to a new terminal and `runAll` opens an agent chat with the page's prompt,
/// both in the file's repository. Only the person's click runs anything, and only for the page's
/// own file.
@MainActor @Suite struct MarkdownRunbookRunTests {
    private final class Host: FilePageHosting {
        private(set) var terminals: [(command: String, cwd: String)] = []
        private(set) var chats: [(prompt: String, cwd: String)] = []
        var roots: FileWorkspaceRoots { FileWorkspaceRoots(folders: []) }
        var remoteImages: Bool { false }
        func recents() -> JSONValue { ["items": []] }
        func record(_: URL) {}
        func chooseFile(start _: URL?) async -> URL? { nil }
        func look() -> JSONValue { .object([:]) }
        func listenLook(_: @escaping @MainActor (JSONValue) -> Void) -> () -> Void { {} }
        func setPreference(key _: String, value _: JSONValue, by _: SettingWriter) async throws {}
        func opened(_: URL) {}
        func openExternal(_: URL) {}
        func openFile(_: URL) {}
        func openAppLink(_: URL) -> Bool { false }
        func isRecent(_: String) -> Bool { false }
        func confirmOpen(_: URL, userGesture _: Bool) async -> Bool { false }
        func edited(_: URL, text _: String, baseHash _: String?, writable _: Bool) -> RecoveryDraftAcceptance { .kept }
        func saved(_: URL, hash _: String) {}
        func run(_ run: RunbookRun, cwd: String) -> Bool {
            if run.target == .chat { chats.append((run.text, cwd)) } else { terminals.append((run.text, cwd)) }
            return true
        }
    }

    private final class NoImages: RemoteImageFetching {
        func fetch(_: URL) async -> PageResource? { nil }
    }

    nonisolated private struct Git: MarkdownGitRunning {
        let top: String?
        func run(_ arguments: [String], in _: String) async -> MarkdownGitOutput? {
            guard arguments == ["rev-parse", "--show-toplevel"] else { return nil }
            return top.map { MarkdownGitOutput(status: 0, output: $0 + "\n") } ?? MarkdownGitOutput(status: 128, output: "")
        }
    }

    @Test func aClickRunsTheBlockAndRunAllOpensAChatOnlyForThisFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "md-runbook-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "deploy.md")
        try Data("# Deploy\n\n```bash\nnpm ci\n```\n".utf8).write(to: file)
        let host = Host()
        let provider = FilePageProvider(kind: .markdown, file: file, host: host, libraries: nil, images: NoImages())
        defer { provider.close() }
        let script = PageCallContext(page: FilePageKind.markdown.namespace)
        let clicked = PageCallContext(page: FilePageKind.markdown.namespace, userGesture: true)
        _ = try await provider.call(FilePageKind.markdown.op("config"), params: [:], context: script)

        do {
            _ = try await provider.call(FilePageKind.markdown.op("runBlock"),
                                        params: ["path": .string(file.path), "command": "npm ci"], context: script)
            Issue.record("a script ran a block without a click")
        } catch let error as PageError {
            #expect(error.code == "cmux.page.gesture")
        }
        do {
            _ = try await provider.call(FilePageKind.markdown.op("runBlock"),
                                        params: ["path": .string(folder.appending(path: "other.md").path), "command": "npm ci"],
                                        context: clicked)
            Issue.record("a click ran a block for another document")
        } catch let error as PageError {
            #expect(error.code == "cmux.protocol.invalid_params")
        }
        do {
            _ = try await provider.call(FilePageKind.markdown.op("runBlock"),
                                        params: ["path": .string(file.path), "command": "  \n"], context: clicked)
            Issue.record("an empty command ran")
        } catch let error as PageError {
            #expect(error.code == "cmux.protocol.invalid_params")
        }
        #expect(host.terminals.isEmpty)

        _ = try await provider.call(FilePageKind.markdown.op("runBlock"),
                                    params: ["path": .string(file.path), "command": "npm ci"], context: clicked)
        _ = try await provider.call(FilePageKind.markdown.op("runAll"),
                                    params: ["path": .string(file.path), "prompt": "Run this runbook"], context: clicked)
        // Outside a repository the steps run in the file's folder.
        let expected = folder.resolvingSymlinksInPath().path
        #expect(host.terminals.map(\.command) == ["npm ci"])
        #expect(host.terminals.map { URL(fileURLWithPath: $0.cwd).resolvingSymlinksInPath().path } == [expected])
        #expect(host.chats.map(\.prompt) == ["Run this runbook"])
        #expect(host.chats.map { URL(fileURLWithPath: $0.cwd).resolvingSymlinksInPath().path } == [expected])
    }

    @Test func stepsRunAtTheRepositoryRoot() async throws {
        let file = URL(fileURLWithPath: "/work/app/docs/deploy.md")
        let run = try RunbookRun(target: .terminal, params: ["command": "make"], userGesture: true, isPageFile: true)
        #expect(await run.folder(for: file, runner: Git(top: "/work/app")) == "/work/app")
        #expect(await run.folder(for: file, runner: Git(top: nil)) == "/work/app/docs")
    }

    @Test func aPromptOrCommandPastItsLimitIsRefused() {
        let long = JSONValue.string(String(repeating: "a", count: RunbookRun.commandLimit + 1))
        #expect(throws: PageError.self) {
            try RunbookRun(target: .terminal, params: ["command": long], userGesture: true, isPageFile: true)
        }
        #expect((try? RunbookRun(target: .chat, params: ["prompt": long], userGesture: true, isPageFile: true))?.target == .chat)
    }

    /// A Cloud machine's runbook does not run on this Mac: the terminal, chat and git root here are not its.
    @Test func aRunbookOfAnotherMachineIsRefused() {
        #expect(throws: PageError.self) {
            try RunbookRun(target: .terminal, params: ["command": "make"], userGesture: true, isPageFile: true, local: false)
        }
        #expect(throws: PageError.self) {
            try RunbookRun(target: .chat, params: ["prompt": "Run it"], userGesture: true, isPageFile: true, local: false)
        }
    }
}
