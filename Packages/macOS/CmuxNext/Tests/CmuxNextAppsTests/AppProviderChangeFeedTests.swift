@testable import CmuxNextApps
import Observation
import Testing

/// The threads template polled `agent_chat.list` every 2 s. The app now sends `apps-provider-changed`
/// for `agent_chat` when its chats change, and the daemon tells subscribers `agent_chat.changed`.
@MainActor @Suite(.serialized) struct AppProviderChangeFeedTests {
    @Observable @MainActor final class Chats { var titles: [String] = ["a"] }

    /// The families sent, in order, as a stream the test reads without sleeping.
    static func recorder() -> (AppProviderChangeFeed.Send, AsyncStream<String>) {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        return ({ family in continuation.yield(family) }, stream)
    }

    @Test func aRegisteredCarrierHearsOnceAtOnceAndOnEachChange() async {
        let chats = Chats()
        let feed = AppProviderChangeFeed(family: "agent_chat") { chats.titles }
        let (send, sent) = Self.recorder()
        var heard = sent.makeAsyncIterator()
        feed.attach(send)
        #expect(await heard.next() == "agent_chat", "a new carrier hears once: the chats may have changed while none was registered")
        chats.titles.append("b")
        #expect(await heard.next() == "agent_chat", "a change of the chats is sent")
        feed.attach(nil)
    }

    @Test func aDetachedFeedSendsOnTheNextCarrier() async {
        let chats = Chats()
        let feed = AppProviderChangeFeed(family: "agent_chat") { chats.titles }
        let (first, firstSent) = Self.recorder()
        var heardFirst = firstSent.makeAsyncIterator()
        feed.attach(first)
        _ = await heardFirst.next()
        feed.attach(nil)
        chats.titles.append("while detached")
        let (second, secondSent) = Self.recorder()
        var heardSecond = secondSent.makeAsyncIterator()
        feed.attach(second)
        #expect(await heardSecond.next() == "agent_chat", "the next carrier hears the change it missed")
        chats.titles.append("c")
        #expect(await heardSecond.next() == "agent_chat")
        feed.attach(nil)
    }
}
