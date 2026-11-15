import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import CmuxNextDaemon
import Observation
import Testing
@testable import CmuxNextAgentPane

/// User 12922: the book keeps the icons of the last harness list, and a list with the same icons
/// is no change (the tab strip and sidebar do not map again for it).
@MainActor
struct HarnessIconBookTests {
    @Test func environmentLookupRunsOffMainOnTheBlockingLane() async {
        let wasMain = Atomic<Bool>(true)
        let book = HarnessIconBook(work: BackgroundWork(), environment: {
            wasMain.store(Thread.isMainThread, ordering: .relaxed)
            return nil
        })
        #expect(await book.resolveEnvironment() == nil)
        let ranOnMain = wasMain.load(ordering: .relaxed)
        #expect(!ranOnMain)
    }

    /// hang-watch 8a1dbcadaa (cmuxterm-hq#11534): the reply carries image icons as inline base64, and
    /// parsing it on the main actor stalled Leo's NIGHTLY. The decode runs on the CPU lane.
    @Test func replyDecodeRunsOffMainOnTheCPULane() async {
        let wasMain = Atomic<Bool>(true)
        let book = HarnessIconBook(work: BackgroundWork(), environment: { nil })
        let data = Data(#"{"harnesses":{"fox":{"iconSpec":{"kind":"emoji","text":"🦊","source":"profile"}}}}"#.utf8)
        let icons = await book.decode(data) { data in
            wasMain.store(Thread.isMainThread, ordering: .relaxed)
            return HarnessIcons(harnessesReplyData: data)
        }
        #expect(icons?.specs == ["fox": .emoji("🦊", isOwn: true)])
        let ranOnMain = wasMain.load(ordering: .relaxed)
        #expect(!ranOnMain)
        #expect(await book.decode(Data("not json".utf8)) == nil)
    }

    /// The payload that hung: many harnesses with large inline PNG icons decode in one pass.
    @Test func aReplyWithLargeImageIconsDecodes() throws {
        let png = Data(repeating: 0x89, count: 256 * 1024)
        var harnesses: [String: Any] = [:]
        for index in 0..<16 {
            harnesses["h\(index)"] = ["iconSpec": ["kind": "image", "mime": "image/png", "data": png.base64EncodedString(), "source": "profile"]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["harnesses": harnesses])
        let icons = try #require(HarnessIcons(harnessesReplyData: data))
        #expect(icons.specs.count == 16)
        #expect(icons.specs["h0"] == .image(png, mime: "image/png", isOwn: true))
    }

    @Test func aReplysIconsReplaceTheBooksOnlyWhenTheyChange() {
        let book = HarnessIconBook(work: BackgroundWork(), environment: { nil })
        #expect(book.icons == .none)
        let reply: [String: Any] = ["harnesses": [
            "fox": ["iconSpec": ["kind": "emoji", "text": "🦊", "source": "profile"]],
            "bad": ["iconSpec": ["kind": "image", "mime": "text/html", "data": "PA==", "source": "profile"]],
            "plain": ["kind": "acp"],
        ]]
        book.apply(HarnessIcons(harnessesReply: reply))
        #expect(book.icons.specs == ["fox": .emoji("🦊", isOwn: true)])
        let changes = Atomic<Int>(0)
        withObservationTracking { _ = book.icons } onChange: { changes.wrappingAdd(1, ordering: .relaxed) }
        book.apply(HarnessIcons(harnessesReply: reply))
        #expect(changes.load(ordering: .relaxed) == 0)
        book.apply(HarnessIcons(harnessesReply: ["harnesses": [:]]))
        #expect(changes.load(ordering: .relaxed) == 1)
        #expect(book.icons == .none)
    }
}
