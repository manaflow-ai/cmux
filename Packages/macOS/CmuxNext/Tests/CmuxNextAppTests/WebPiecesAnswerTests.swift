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
    static func answer(paneServe: String, paneUpdate: String?, refusedActive: Bool = false) -> Data {
        let update = paneUpdate.map { "\"\($0)\"" } ?? "null"
        return Data("""
        a line the command printed before
        {"taken":true,"refusal":null,"serial":7,"switches":{},"refuse":[],"refused_active":\(refusedActive),"fetch":{"status":200},"pieces":{"agent-pane":{"output":"\(pane)","update":\(update),"serve":"\(paneServe)","reason":"blank pane"},"pages":{"output":"\(pages)","update":"live1","serve":"live","reason":""}},"log":{"event":"web-pieces"}}

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
        let (switched, used) = await WebUpdates.resolve(answer, [], store)
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
        let (switched, used) = await WebUpdates.resolve(answer, [pointer], store)
        #expect(switched == [Self.pane: nil])
        #expect(used.isEmpty)
        // An update the app holds no pointer for is not served either.
        #expect(await WebUpdates.resolve(answer, [], store).0 == [Self.pane: nil])
    }

    @Test func theKeptPointersLastWhileAPieceIsSwitchedOut() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "web-pieces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = WebUpdateStore(base: base)
        let pointer = WebUpdatePointer(channel: "every-merge", key: "old1", archive: "a.tar.gz", sha256: "", size: 0,
                                       outputs: "o", abi: 1, commit: "c", committedAt: 1, publishedAt: 1)
        #expect(!(await WebUpdates.hasKept(store)))
        await WebUpdates.keep([pointer], switched: true, in: store)
        #expect(await WebUpdates.hasKept(store))
        #expect(await WebUpdates.kept(store) == [pointer])
        // Switched to the bundle only: no pointer, but the next launch still asks.
        await WebUpdates.keep([], switched: true, in: store)
        #expect(await WebUpdates.hasKept(store))
        #expect(await WebUpdates.kept(store).isEmpty)
        await WebUpdates.keep([], in: store)
        #expect(!(await WebUpdates.hasKept(store)))
    }
}
