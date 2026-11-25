import CmuxNextUpdater
@testable import CmuxNextWebUpdates
import Foundation
import Testing

/// The web pieces switched out remotely (WebUpdates+Pieces.swift): the app reads the answer of
/// `cmux app web-pieces check` and maps each switched-out piece onto a folder it has checked.
@Suite struct WebPiecesAnswerTests {
    static let pane = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"
    static let pages = "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"

    /// What `cmux app web-pieces check` prints (cmux-web-pieces `evaluate`, plus the CLI's own fields).
    static func answer(paneServe: String, paneUpdate: String?, refusedActive: Bool = false, drillRefusedActive: Bool? = nil) -> Data {
        let update = paneUpdate.map { "\"\($0)\"" } ?? "null"
        let drill = drillRefusedActive.map { "\"drill_refused_active\":\($0)," } ?? ""
        return Data("""
        a line the command printed before
        {"taken":true,"refusal":null,"serial":7,"switches":{},"refuse":[],"refused_active":\(refusedActive),\(drill)"fetch":{"status":200},"pieces":{"agent-pane":{"output":"\(pane)","update":\(update),"serve":"\(paneServe)","reason":"blank pane"},"pages":{"output":"\(pages)","update":"live1","serve":"live","reason":""}},"log":{"event":"web-pieces"}}

        """.utf8)
    }

    @Test func theAnswerNamesTheSwitchedOutPieces() throws {
        let answer = try #require(WebPiecesAnswer.parse(Self.answer(paneServe: "bundled", paneUpdate: nil)))
        #expect(answer.serial == 7)
        #expect(!answer.refusedActive)
        #expect(answer.switched.keys.sorted() == ["agent-pane"])
        #expect(answer.switched["agent-pane"]?.reason == "blank pane")
        #expect(try #require(WebPiecesAnswer.parse(Self.answer(paneServe: "live", paneUpdate: "live1", refusedActive: true))).refusedActive)
        // No answer: what is served stays.
        #expect(WebPiecesAnswer.parse(Data("error: no such folder\n".utf8)) == nil)
        #expect(WebPiecesAnswer.parse(Data()) == nil)
    }

    @Test func aPieceSwitchedToTheBundleNeedsNoFolder() async throws {
        let store = WebUpdateStore(base: FileManager.default.temporaryDirectory.appending(path: "web-pieces-\(UUID().uuidString)"))
        let answer = try #require(WebPiecesAnswer.parse(Self.answer(paneServe: "bundled", paneUpdate: nil)))
        let (switched, used, _) = await WebUpdates.resolve(answer, [], store)
        #expect(switched == [Self.pane: nil])
        #expect(used.isEmpty)
    }

    /// The last good update is served only while its files match its signed pointer: an update
    /// that is not on disk (or changed there) leaves the piece on the bundle, never on the live one.
    @Test func aLastGoodUpdateThatDoesNotVerifyServesTheBundle() async throws {
        let store = WebUpdateStore(base: FileManager.default.temporaryDirectory.appending(path: "web-pieces-\(UUID().uuidString)"))
        let answer = try #require(WebPiecesAnswer.parse(Self.answer(paneServe: "last-good", paneUpdate: "old1")))
        let pointer = WebUpdatePointer(channel: "every-merge", key: "old1", archive: "a.tar.gz", sha256: "", size: 0,
                                       outputs: "nope", abi: 1, commit: "c", committedAt: 1, publishedAt: 1)
        let (switched, used, verified) = await WebUpdates.resolve(answer, [pointer], store)
        #expect(switched == [Self.pane: nil])
        #expect(used.isEmpty)
        #expect(verified.isEmpty)
        // An update the app holds no pointer for is not served either.
        #expect(await WebUpdates.resolve(answer, [], store).0 == [Self.pane: nil])
    }

    /// A kept update verified once in this run is not hashed again on the next read: its folder
    /// comes from the cache, even with no files on disk to hash.
    @Test func aVerifiedUpdateIsNotHashedAgain() async throws {
        let store = WebUpdateStore(base: FileManager.default.temporaryDirectory.appending(path: "web-pieces-\(UUID().uuidString)"))
        let answer = try #require(WebPiecesAnswer.parse(Self.answer(paneServe: "last-good", paneUpdate: "old1")))
        let pointer = WebUpdatePointer(channel: "every-merge", key: "old1", archive: "a.tar.gz", sha256: "", size: 0,
                                       outputs: "nope", abi: 1, commit: "c", committedAt: 1, publishedAt: 1)
        let folder = URL(fileURLWithPath: "/verified/old1", isDirectory: true)
        let (switched, used, fresh) = await WebUpdates.resolve(answer, [pointer], store, verified: ["old1": folder])
        #expect(switched == [Self.pane: folder])
        #expect(used == [pointer])
        #expect(fresh.isEmpty)
        // A cached folder of an update the app no longer holds a pointer for is not served.
        #expect(await WebUpdates.resolve(answer, [], store, verified: ["old1": folder]).0 == [Self.pane: nil])
    }

    /// The cache holds for one set of kept updates; a new set starts empty.
    @Test func theVerifiedCacheResetsWhenTheKeptSetChanges() {
        var cache = VerifiedTrees()
        let folder = URL(fileURLWithPath: "/verified/old1", isDirectory: true)
        let first = cache.held(for: ["old1"])
        #expect(first.isEmpty)
        cache.add(["old1": folder], for: ["old1"])
        let kept = cache.held(for: ["old1"])
        #expect(kept == ["old1": folder])
        // Verified for a set that is no longer held: not kept.
        cache.add(["old2": folder], for: ["old2"])
        let still = cache.held(for: ["old1"])
        #expect(still == ["old1": folder])
        let grown = cache.held(for: ["old1", "old2"])
        #expect(grown.isEmpty)
        let back = cache.held(for: ["old1"])
        #expect(back.isEmpty)
    }

    @Test func theRefusedAnswerParses() {
        #expect(WebPiecesRefused.parse(Data("a line before\n{\"refused\":true,\"serial\":4}\n".utf8)) == WebPiecesRefused(refused: true))
        #expect(WebPiecesRefused.parse(Data("{\"refused\":false,\"serial\":0}".utf8)) == WebPiecesRefused(refused: false))
        #expect(WebPiecesRefused.parse(Data("usage: cmux app web-pieces\n".utf8)) == nil)
        #expect(WebPiecesRefused.parse(Data()) == nil)
    }

    @Test func theKeptPointersLastWhileAPieceIsSwitchedOut() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "web-pieces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let pointer = WebUpdatePointer(channel: "every-merge", key: "old1", archive: "a.tar.gz", sha256: "", size: 0,
                                       outputs: "o", abi: 1, commit: "c", committedAt: 1, publishedAt: 1)
        let kept = WebUpdates.keptFile
        #expect(!(await WebUpdates.has(kept, in: base)))
        await WebUpdates.keep([pointer], switched: true, in: base)
        #expect(await WebUpdates.has(kept, in: base))
        #expect(await WebUpdates.kept(in: base) == [pointer])
        // Switched to the bundle only: no pointer, but the next launch still asks.
        await WebUpdates.keep([], switched: true, in: base)
        #expect(await WebUpdates.has(kept, in: base))
        #expect(await WebUpdates.kept(in: base).isEmpty)
        await WebUpdates.keep([], in: base)
        #expect(!(await WebUpdates.has(kept, in: base)))
    }
}
