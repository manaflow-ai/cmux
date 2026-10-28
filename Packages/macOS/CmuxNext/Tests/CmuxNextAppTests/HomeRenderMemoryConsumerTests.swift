import CmuxHomeCore
import CmuxHomeRender
import CmuxNextCompat
import CmuxNextHome
import CoreGraphics
import Foundation
import Testing

/// The Home render caches as memory consumers: one lossless consumer per live
/// controller with an equal share of the group's budget, scaled by the limit; a release trims to it,
/// limit 0 keeps only what the rows on screen show, the measurements stay, a hidden transcript holds
/// no image, and rows draw again afterwards.
@MainActor
struct HomeRenderMemoryConsumerTests {
    /// A registry that hands each new consumer `limit` at once, as the coordinator does.
    private final class FakeRegistry: MemoryConsumerRegistry {
        var limit = MemoryLimit.default
        var entries: [MemoryConsumerEntry] = []

        func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
            entries.append(entry)
            entry.liveConsumer?.updateMemoryLimit(limit)
        }
    }

    /// A cleanup deadline that never fires (these tests run no animation to its end).
    private final class IdleDeadline: HomeDeadline {
        func schedule(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    private static let me = ParticipantID("user_me")
    private static let chief = ParticipantID("agent_chief")
    private static let conversation = ConversationID("conv_memory")
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)
    private static let mebibyte = 1 << 20

    private static func slice(_ percent: Int) -> MemoryReleaseSlice {
        MemoryReleaseSlice(limit: MemoryLimit(percent: percent)) { false }
    }

    private static func controller(budgetBytes: Int = 256 << 20) -> HomeController {
        let palette = HomePalette.themed(HomePalette.Theme(background: .gray255(25), foreground: .gray255(255),
                                                           accent: .rgb255(52, 168, 96), failure: .rgb255(235, 70, 60)))
        let c = HomeController(conversation: conversation, me: me, palette: palette, deadline: IdleDeadline(),
                               memoryBudget: HomeMemoryBudget(bytes: budgetBytes))
        c.resize(to: CGSize(width: 628, height: 900))
        return c
    }

    /// `count` short messages alternating between the Chief and me, laid out and drawn.
    private static func show(_ count: Int, in c: HomeController) async {
        let messages: [Message] = (0..<count).map { (i: Int) -> Message in
            let number = i + 1
            let author: ParticipantID = i % 2 == 0 ? chief : me
            let text = "Message \(number): the fleet build finished."
            let createdAt = start.addingTimeInterval(Double(i) * 30)
            return Message(id: MessageID("msg_\(number)"), conversation: conversation, seq: Seq(number),
                           clientMessageID: IdempotencyKey("key_\(number)"), author: author,
                           parts: [.text(text)], createdAt: createdAt)
        }
        c.update(items: TranscriptWindow(messages: messages).items(pending: [], me: me), summary: nil, typing: [], hasOlder: false)
        await c.bitmapsSettled()
    }

    /// The memory report of a controller that holds no bitmap or picture: its measurements alone.
    private static func measurementsOnly(_ c: HomeController) -> MemoryUsage {
        MemoryUsage(footprintBytes: c.measurementBytes, entries: c.measurementCount)
    }

    @Test func eachControllerRegistersOnceAndSharesTheBudgetEqually() {
        let registry = FakeRegistry()
        let group = HomeRenderMemoryConsumers(budgetBytes: 120 * Self.mebibyte, registry: registry)
        let first = Self.controller(), second = Self.controller()

        let a = group.register(first)
        #expect(first.memoryBudget.bytes == 120 * Self.mebibyte)
        let b = group.register(second)

        #expect(registry.entries.map(\.name) == ["home-render", "home-render"])
        #expect(registry.entries.allSatisfy { $0.traits == HomeRenderMemoryConsumer.memoryTraits })
        #expect(first.memoryBudget.bytes == 60 * Self.mebibyte)
        #expect(second.memoryBudget.bytes == 60 * Self.mebibyte)

        b.cancel()
        #expect(group.count == 1)
        #expect(registry.entries.last?.isLive == false, "a closed controller is never called again")
        #expect(first.memoryBudget.bytes == 120 * Self.mebibyte, "the one left takes the closed one's share")
        withExtendedLifetime(a) {}
    }

    @Test func theCurrentLimitScalesTheShareAtRegistration() {
        let registry = FakeRegistry()
        registry.limit = MemoryLimit(percent: 50)
        let group = HomeRenderMemoryConsumers(budgetBytes: 120 * Self.mebibyte, registry: registry)
        let c = Self.controller()

        let consumer = group.register(c)

        #expect(consumer.allowedBytes == 60 * Self.mebibyte)
        #expect(c.memoryBudget.bytes == 60 * Self.mebibyte)
    }

    @Test func aReleaseTrimsToTheLimitAndLimitZeroKeepsOnlyWhatTheScreenShows() async {
        let c = Self.controller()
        await Self.show(12, in: c)
        let onScreen = c.memoryBytes
        #expect(onScreen > 0)
        await Self.show(400, in: c)  // the rows drawn for the first 12 scrolled away
        let held = c.memoryBytes
        #expect(held > onScreen)
        let group = HomeRenderMemoryConsumers(budgetBytes: held, registry: FakeRegistry())
        let consumer = group.register(c)
        #expect(c.memoryBytes == held, "registering lowers caps and frees nothing")

        #expect(consumer.releaseMemory(within: Self.slice(0)) == .done)
        #expect(c.memoryBytes < held)
        #expect(c.memoryBytes > 0, "the rows on screen keep what their layers show")
        let measurements = c.measurementBytes
        #expect(measurements > 0, "measurements are never released")
        #expect(consumer.memoryUsage?.footprintBytes == c.memoryBytes + measurements)

        let kept = c.memoryBytes
        consumer.updateMemoryLimit(.default)
        #expect(c.memoryBudget.bytes == held)
        await Self.show(401, in: c)
        #expect(c.memoryBytes >= kept, "the next commit draws again")
    }

    @Test func aHiddenTranscriptHoldsNoImageUntilItShowsAgain() async {
        let group = HomeRenderMemoryConsumers(budgetBytes: 120 * Self.mebibyte, registry: FakeRegistry())
        let c = Self.controller()
        let consumer = group.register(c)
        await Self.show(12, in: c)
        let shown = consumer.memoryUsage?.footprintBytes ?? 0
        #expect(shown > 0)

        consumer.setHidden(true)
        #expect(c.isHidden)
        #expect(c.memoryBytes == 0)
        #expect(consumer.memoryUsage == Self.measurementsOnly(c), "only the measurements every commit reads stay")
        #expect(c.memoryBudget.bytes == 0)

        consumer.setHidden(false)
        #expect(c.memoryBudget.bytes == 120 * Self.mebibyte)
        await Self.show(13, in: c)
        #expect(c.memoryBytes > 0)
    }
}
