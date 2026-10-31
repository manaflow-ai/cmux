import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite struct ClaudeTranscriptAccountSyncTests {
    private let fm = FileManager.default

    private func makeRoot() throws -> String {
        let root = NSTemporaryDirectory() + "acct-sync-\(UUID().uuidString)"
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func slug(_ cwd: String) -> String { ClaudeProjectSlug().slug(forWorkingDirectory: cwd) }

    /// A transcript after one turn, shaped like Claude Code's: session metadata, then the messages.
    private static let conversation = """
        {"type":"ai-title","aiTitle":"title","sessionId":"s1"}
        {"type":"permission-mode","permissionMode":"default","sessionId":"s1"}
        {"type":"user","message":{"role":"user","content":"Reply OK"},"sessionId":"s1"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"OK"}]},"sessionId":"s1"}

        """

    /// What Claude Code writes before the first turn when the session has a name: metadata, no message.
    private static let metadataOnly = """
        {"type":"ai-title","aiTitle":"title","sessionId":"s1"}
        {"type":"agent-name","agentName":"title","sessionId":"s1"}

        """

    @discardableResult
    private func seedSource(
        root: String, cwd: String, body: String = Self.conversation, mtime: Date? = nil
    ) throws -> String {
        let project = "\(root)/src/projects/\(slug(cwd))"
        try fm.createDirectory(atPath: "\(project)/s1/subagents", withIntermediateDirectories: true)
        try body.write(toFile: "\(project)/s1.jsonl", atomically: true, encoding: .utf8)
        try "sub".write(toFile: "\(project)/s1/subagents/a.jsonl", atomically: true, encoding: .utf8)
        if let mtime { try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: "\(project)/s1.jsonl") }
        return "\(project)/s1.jsonl"
    }

    private func request(root: String, cwd: String, sid: String = "s1") -> ClaudeTranscriptAccountSyncRequest {
        .init(sessionID: sid, workingDirectory: cwd, sourceConfigDirectory: "\(root)/src",
              targetConfigDirectory: "\(root)/dst")
    }

    @Test func copiesWhenTargetMissing() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        let src = try seedSource(root: root, cwd: "/p")
        let outcome = try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p"))
        #expect(outcome == .copied)
        let dst = "\(root)/dst/projects/\(slug("/p"))/s1.jsonl"
        #expect(try Data(contentsOf: URL(fileURLWithPath: dst)) == Data(contentsOf: URL(fileURLWithPath: src)))
        #expect(fm.fileExists(atPath: "\(root)/dst/projects/\(slug("/p"))/s1/subagents/a.jsonl"))
        // A second sync must see the copy as current.
        let again = try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p"))
        #expect(again == .alreadyCurrent)
    }

    private func targetProject(_ root: String, cwd: String = "/p") -> String {
        "\(root)/dst/projects/\(slug(cwd))"
    }

    private func setModificationDate(_ date: Date, _ path: String) throws {
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    /// The first two lines of ``conversation``: what the other account saw before the last turn.
    private static let conversationPrefix = conversation.components(separatedBy: "\n").prefix(2)
        .joined(separator: "\n") + "\n"

    private static func userLine(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":""# + text + #""}}"# + "\n"
    }

    /// A target that holds only the start of the source's transcript is refreshed, even when its
    /// mtime is newer: Claude Code transcripts are append-only, so the content decides.
    @Test func refreshesATargetThatIsAPrefixOfTheSourceWhateverItsMtime() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        let now = Date()
        let src = try seedSource(root: root, cwd: "/p", mtime: now)
        let dstProject = targetProject(root)
        try fm.createDirectory(atPath: "\(dstProject)/s1/old", withIntermediateDirectories: true)
        try Self.conversationPrefix.write(toFile: "\(dstProject)/s1.jsonl", atomically: true, encoding: .utf8)
        try setModificationDate(now.addingTimeInterval(60), "\(dstProject)/s1.jsonl")

        let outcome = try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p"))

        #expect(outcome == .refreshed)
        #expect(try Data(contentsOf: URL(fileURLWithPath: "\(dstProject)/s1.jsonl"))
                == Data(contentsOf: URL(fileURLWithPath: src)))
        #expect(fm.fileExists(atPath: "\(dstProject)/s1/subagents/a.jsonl"))
        #expect(!fm.fileExists(atPath: "\(dstProject)/s1/old"))
        let leftovers = try fm.contentsOfDirectory(atPath: dstProject).filter { $0.contains(".tmp-") }
        #expect(leftovers.isEmpty)
    }

    /// A target that already continues the source's transcript (the conversation went on under
    /// the target account) is kept, even when its mtime is older, and so is its sidecar.
    @Test func keepsATargetThatContinuesTheSourceWhateverItsMtime() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        let now = Date()
        try seedSource(root: root, cwd: "/p", mtime: now.addingTimeInterval(60))
        let dstProject = targetProject(root)
        let continued = Self.conversation + Self.userLine("more")
        try fm.createDirectory(atPath: "\(dstProject)/s1/target-only", withIntermediateDirectories: true)
        try continued.write(toFile: "\(dstProject)/s1.jsonl", atomically: true, encoding: .utf8)
        try setModificationDate(now, "\(dstProject)/s1.jsonl")

        let outcome = try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p"))

        #expect(outcome == .alreadyCurrent)
        #expect(try String(contentsOfFile: "\(dstProject)/s1.jsonl", encoding: .utf8) == continued)
        #expect(fm.fileExists(atPath: "\(dstProject)/s1/target-only"))
        #expect(!fm.fileExists(atPath: "\(dstProject)/s1/subagents"))
    }

    /// The same conversation continued separately under both accounts: neither copy is a prefix
    /// of the other. The sync refuses and leaves both copies and the target sidecar untouched,
    /// whichever copy is newer, because overwriting either one loses turns.
    @Test(arguments: [false, true])
    func refusesDivergedCopiesAndTouchesNothing(targetIsNewer: Bool) async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        let now = Date()
        let sourceBody = Self.conversationPrefix + Self.userLine("A")
        let targetBody = Self.conversationPrefix + Self.userLine("B")
        let src = try seedSource(
            root: root, cwd: "/p", body: sourceBody, mtime: now.addingTimeInterval(targetIsNewer ? 0 : 60)
        )
        let dstProject = targetProject(root)
        try fm.createDirectory(atPath: "\(dstProject)/s1/target-only", withIntermediateDirectories: true)
        try targetBody.write(toFile: "\(dstProject)/s1.jsonl", atomically: true, encoding: .utf8)
        try setModificationDate(now.addingTimeInterval(targetIsNewer ? 60 : 0), "\(dstProject)/s1.jsonl")

        await #expect(throws: (any Error).self) {
            try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p"))
        }
        let error = try #require(await syncError(request(root: root, cwd: "/p")))
        #expect(error as? ClaudeTranscriptAccountSyncError == .diverged(targetIsNewer: targetIsNewer))
        // The switch names the account whose copy was written last.
        #expect(ClaudeAccountSwitchRefusal(transcriptSyncError: error, sourceAccountName: "a", targetAccountName: "b")
                == .transcriptDiverged(newerAccount: targetIsNewer ? "b" : "a"))

        #expect(try String(contentsOfFile: "\(dstProject)/s1.jsonl", encoding: .utf8) == targetBody)
        #expect(try String(contentsOfFile: src, encoding: .utf8) == sourceBody)
        #expect(fm.fileExists(atPath: "\(dstProject)/s1/target-only"))
        #expect(!fm.fileExists(atPath: "\(dstProject)/s1/subagents"))
    }

    /// An identical copy is current; a sidecar only the source has is filled in, because both
    /// copies describe the same conversation state.
    @Test func fillsTheMissingSidecarOfAnIdenticalCopy() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        try seedSource(root: root, cwd: "/p")
        let dstProject = targetProject(root)
        try fm.createDirectory(atPath: dstProject, withIntermediateDirectories: true)
        try Self.conversation.write(toFile: "\(dstProject)/s1.jsonl", atomically: true, encoding: .utf8)

        let outcome = try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p"))

        #expect(outcome == .refreshed)
        #expect(fm.fileExists(atPath: "\(dstProject)/s1/subagents/a.jsonl"))
        #expect(try String(contentsOfFile: "\(dstProject)/s1.jsonl", encoding: .utf8) == Self.conversation)
    }

    /// Claude Code can keep a transcript at `<sid>/messages/<sid>.jsonl`, inside the sidecar
    /// directory; the prefix rule applies to it the same way, mtimes notwithstanding.
    @Test func appliesThePrefixRuleToTheNestedMessagesLayout() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        let sourceNested = "\(root)/src/projects/\(slug("/p"))/s1/messages/s1.jsonl"
        let targetNested = "\(targetProject(root))/s1/messages/s1.jsonl"
        try fm.createDirectory(
            atPath: (sourceNested as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try Self.conversation.write(toFile: sourceNested, atomically: true, encoding: .utf8)

        #expect(try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p")) == .copied)
        #expect(try String(contentsOfFile: targetNested, encoding: .utf8) == Self.conversation)

        // The target account went on, and its copy is older by mtime: still kept.
        let continued = Self.conversation + Self.userLine("more")
        try continued.write(toFile: targetNested, atomically: true, encoding: .utf8)
        try setModificationDate(Date().addingTimeInterval(-60), targetNested)
        #expect(try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p")) == .alreadyCurrent)
        #expect(try String(contentsOfFile: targetNested, encoding: .utf8) == continued)

        // The source caught up past the target: the target is a prefix again and is refreshed.
        let further = continued + Self.userLine("again")
        try further.write(toFile: sourceNested, atomically: true, encoding: .utf8)
        #expect(try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p")) == .refreshed)
        #expect(try String(contentsOfFile: targetNested, encoding: .utf8) == further)
    }

    @Test func syncsTranscriptForCwdWithSpacesAndUnicode() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        let cwd = "/tmp/my proj/한글"
        try seedSource(root: root, cwd: cwd)
        let outcome = try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: cwd))
        #expect(outcome == .copied)
        #expect(fm.fileExists(atPath: "\(root)/dst/projects/\(slug(cwd))/s1.jsonl"))
    }

    @Test func missingSourceThrows() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        await #expect(throws: ClaudeTranscriptAccountSyncError.transcriptNotFound) {
            try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p"))
        }
    }

    private static let unresumableSources: [(String, String)] = [
        ("metadata only", metadataOnly),
        ("empty file", ""),
        ("blank lines", "\n\n"),
        ("message type nested in a metadata record", #"{"type":"attachment","attachment":{"type":"user"}}"# + "\n"),
        ("type that only starts like a message", #"{"type":"user-prompt-draft","sessionId":"s1"}"# + "\n"),
        ("partial message line", #"{"type":"user","message":{"role":"user","#),
        ("not JSON", "line1\nline2\n"),
    ]

    /// Sources `claude --resume` finds no conversation in. The sync refuses them before it touches
    /// the target, so a switch never types a resume that exits with "No conversation found".
    @Test(arguments: unresumableSources)
    func refusesASourceWithoutAConversation(_ label: String, body: String) async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        try seedSource(root: root, cwd: "/p", body: body)
        await #expect(throws: ClaudeTranscriptAccountSyncError.noConversation, "\(label)") {
            try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p"))
        }
        #expect(!fm.fileExists(atPath: "\(root)/dst"), "\(label): the target must stay untouched")
    }

    /// Switching back after a metadata-only copy reached the target: both sides are equally
    /// current and the source still has no conversation, so it is refused, not `alreadyCurrent`.
    @Test func refusesAMetadataOnlySourceEvenWhenTheTargetHasTheSameCopy() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        let now = Date()
        try seedSource(root: root, cwd: "/p", body: Self.metadataOnly, mtime: now)
        let dstProject = "\(root)/dst/projects/\(slug("/p"))"
        try fm.createDirectory(atPath: "\(dstProject)/s1/subagents", withIntermediateDirectories: true)
        try Self.metadataOnly.write(toFile: "\(dstProject)/s1.jsonl", atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: "\(dstProject)/s1.jsonl")
        await #expect(throws: ClaudeTranscriptAccountSyncError.noConversation) {
            try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p"))
        }
    }

    private static let userRecord = #"{"type":"user","message":{"role":"user","content":"hi"}}"#
    private static let longAttachmentRecord: String = {
        let content = String(repeating: "x", count: 200_000)
        return #"{"type":"attachment","content":""# + content + #""}"#
    }()
    private static let resumableSources: [(String, String)] = [
        ("user record only", userRecord + "\n"),
        ("assistant record only", #"{"type":"assistant","message":{"role":"assistant","content":[]}}"# + "\n"),
        ("metadata then a turn", conversation),
        ("user record after a 200 KB attachment line", longAttachmentRecord + "\n" + userRecord + "\n"),
        ("user record on a last line without a newline", metadataOnly + userRecord),
    ]

    /// One user or assistant record anywhere makes the source resumable, including after a line
    /// longer than one read and on a last line with no newline.
    @Test(arguments: resumableSources)
    func copiesASourceWithAConversation(_ label: String, body: String) async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        let src = try seedSource(root: root, cwd: "/p", body: body)
        let outcome = try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p"))
        #expect(outcome == .copied, "\(label)")
        let dst = "\(root)/dst/projects/\(slug("/p"))/s1.jsonl"
        #expect(try Data(contentsOf: URL(fileURLWithPath: dst)) == Data(contentsOf: URL(fileURLWithPath: src)))
    }

    private func syncError(_ request: ClaudeTranscriptAccountSyncRequest) async -> (any Error)? {
        do {
            _ = try await ClaudeTranscriptAccountSync().sync(request)
            return nil
        } catch {
            return error
        }
    }

    /// The account switch turns a sync that found no conversation, whether Claude Code has not
    /// created the transcript yet or wrote only metadata, into the no-conversation refusal. Any
    /// other failure stays an unavailable transcript.
    @Test func switchRefusesOnlyTheNoConversationFailures() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        func refusal(_ error: any Error) -> ClaudeAccountSwitchRefusal? {
            ClaudeAccountSwitchRefusal(transcriptSyncError: error, sourceAccountName: "a", targetAccountName: "b")
        }
        let missing = try #require(await syncError(request(root: root, cwd: "/p")))
        #expect(refusal(missing) == .noConversationYet)

        try seedSource(root: root, cwd: "/p", body: Self.metadataOnly)
        let metadataOnly = try #require(await syncError(request(root: root, cwd: "/p")))
        #expect(refusal(metadataOnly) == .noConversationYet)

        let unsafeSessionID = try #require(await syncError(request(root: root, cwd: "/p", sid: "../x")))
        #expect(refusal(unsafeSessionID) == nil)
        #expect(refusal(CocoaError(.fileReadNoPermission)) == nil)
    }

    @Test func rejectsUnsafeSessionID() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        await #expect(throws: ClaudeTranscriptAccountSyncError.invalidSessionID) {
            try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/p", sid: "../x"))
        }
    }

    @Test func findsSourceInOtherProjectDirWhenCwdSlugDiffers() async throws {
        let root = try makeRoot(); defer { try? fm.removeItem(atPath: root) }
        try seedSource(root: root, cwd: "/old/cwd")
        let outcome = try await ClaudeTranscriptAccountSync().sync(request(root: root, cwd: "/new/cwd"))
        #expect(outcome == .copied)
        #expect(fm.fileExists(atPath: "\(root)/dst/projects/\(slug("/new/cwd"))/s1.jsonl"))
    }
}
