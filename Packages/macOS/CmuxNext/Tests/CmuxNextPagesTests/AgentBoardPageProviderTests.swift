import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The Agent Board page's host (``AgentBoardPageProvider``) at its boundary with the page: it reads
/// only the ledger folder, shows and opens only what a ledger names, and turns the board on only
/// from the person's own click or key, since that changes what every new agent session is given.
@MainActor
struct AgentBoardPageProviderTests {
    static let page = PageCallContext(page: PageDescriptor.agentBoard.id)
    static let click = PageCallContext(page: PageDescriptor.agentBoard.id, userGesture: true)

    final class Recorder {
        var writes: [Bool] = []
        var openedFiles: [URL] = []
        var openedLinks: [URL] = []
    }

    struct Folder {
        let url: URL
        let image: URL
        let other: URL
    }

    /// A ledger folder with one ledger naming `shot.png` and a PR link, plus an image no ledger names.
    static func folder() throws -> Folder {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-board-\(UUID().uuidString)")
        let ledgers = root.appendingPathComponent("ledgers", isDirectory: true)
        try FileManager.default.createDirectory(at: ledgers, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("shot.png")
        let other = root.appendingPathComponent("private.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: other)
        let lines = [
            #"{"kind":"task","id":"t","title":"Invite link","pr":"https://github.com/example/cmux/pull/1"}"#,
            #"{"kind":"evidence","id":"ev","type":"screenshot","path":"\#(image.path)"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: ledgers.appendingPathComponent("s-1.jsonl"), atomically: true, encoding: .utf8)
        try "not a ledger".write(to: ledgers.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        return Folder(url: ledgers, image: image, other: other)
    }

    static func provider(_ folder: Folder, enabled: Bool = false, recorder: Recorder) -> AgentBoardPageProvider {
        AgentBoardPageProvider(
            folder: folder.url,
            enabled: { enabled },
            write: { recorder.writes.append($0) },
            openFile: { recorder.openedFiles.append($0) },
            openLink: { recorder.openedLinks.append($0); return true })
    }

    @Test func stateListsOnlyTheLedgersWithTheSetting() async throws {
        let folder = try Self.folder()
        let provider = Self.provider(folder, enabled: true, recorder: Recorder())
        let state = try await provider.call("cmux.agentBoard.state", params: .object([:]), context: Self.page)
        #expect(state["enabled"] == true)
        let files = state["ledgers"]?.arrayValue?.compactMap { $0["file"]?.stringValue }
        #expect(files == ["s-1.jsonl"])
        #expect(state["ledgers"]?.arrayValue?.first?["text"]?.stringValue?.contains("Invite link") == true)
    }

    @Test func aMissingFolderIsNoLedgers() async throws {
        let missing = Folder(url: URL(fileURLWithPath: "/nonexistent/agent-board-\(UUID().uuidString)"), image: URL(fileURLWithPath: "/x"), other: URL(fileURLWithPath: "/y"))
        let state = try await Self.provider(missing, recorder: Recorder()).call("cmux.agentBoard.state", params: .object([:]), context: Self.page)
        #expect(state["ledgers"]?.arrayValue?.isEmpty == true)
        #expect(state["enabled"] == false)
    }

    @Test func turningOnNeedsThePersonsGesture() async throws {
        let recorder = Recorder()
        let provider = Self.provider(try Self.folder(), recorder: recorder)
        let error = await #expect(throws: PageError.self) {
            try await provider.call("cmux.agentBoard.setEnabled", params: ["on": true], context: Self.page)
        }
        #expect(error?.code == PageNativeOp.userOnlyCode)
        #expect(recorder.writes.isEmpty)
        let reply = try await provider.call("cmux.agentBoard.setEnabled", params: ["on": true], context: Self.click)
        #expect(reply["enabled"] == true)
        #expect(recorder.writes == [true])
    }

    @Test func evidenceReadsOnlyImagesALedgerNames() async throws {
        let folder = try Self.folder()
        let provider = Self.provider(folder, recorder: Recorder())
        let image = try await provider.call("cmux.agentBoard.evidence", params: ["path": .string(folder.image.path)], context: Self.page)
        #expect(image["dataURL"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)
        let unnamed = await #expect(throws: PageError.self) {
            try await provider.call("cmux.agentBoard.evidence", params: ["path": .string(folder.other.path)], context: Self.page)
        }
        #expect(unnamed?.code == "cmux.agentBoard.notInLedger")
        let notImage = await #expect(throws: PageError.self) {
            try await provider.call("cmux.agentBoard.evidence", params: ["path": "/etc/hosts"], context: Self.page)
        }
        #expect(notImage?.code == "cmux.agentBoard.notImage")
    }

    @Test func openTakesOnlyNamedTargetsFromThePerson() async throws {
        let folder = try Self.folder()
        let recorder = Recorder()
        let provider = Self.provider(folder, recorder: recorder)
        let scripted = await #expect(throws: PageError.self) {
            try await provider.call("cmux.agentBoard.open", params: ["path": .string(folder.image.path)], context: Self.page)
        }
        #expect(scripted?.code == PageNativeOp.userOnlyCode)
        let unnamed = await #expect(throws: PageError.self) {
            try await provider.call("cmux.agentBoard.open", params: ["path": .string(folder.other.path)], context: Self.click)
        }
        #expect(unnamed?.code == "cmux.agentBoard.notInLedger")
        _ = try await provider.call("cmux.agentBoard.open", params: ["path": .string(folder.image.path)], context: Self.click)
        _ = try await provider.call("cmux.agentBoard.open", params: ["url": "https://github.com/example/cmux/pull/1"], context: Self.click)
        #expect(recorder.openedFiles.map(\.path) == [folder.image.path])
        #expect(recorder.openedLinks.map(\.absoluteString) == ["https://github.com/example/cmux/pull/1"])
        #expect(recorder.openedFiles.allSatisfy { $0.path != folder.other.path })
    }

    /// A new ledger line reaches the page as an event (FSEvents on the folder), with no polling.
    @Test(.timeLimit(.minutes(1))) func aLedgerWriteIsAnEvent() async throws {
        let folder = try Self.folder()
        let provider = Self.provider(folder, recorder: Recorder())
        let (seen, seenContinuation) = AsyncStream<Void>.makeStream()
        let subscription = try await provider.subscribe("cmux.agentBoard.changes", filter: .object([:]), context: Self.page) { _ in
            seenContinuation.yield()
        }
        try #"{"kind":"task","id":"t2","title":"Second"}"#.write(
            to: folder.url.appendingPathComponent("s-2.jsonl"), atomically: true, encoding: .utf8)
        var iterator = seen.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        subscription.cancel()
    }
}
