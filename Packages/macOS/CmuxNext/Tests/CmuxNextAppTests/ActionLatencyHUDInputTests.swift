import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextFocusUI
import CmuxNextInputCore
import Testing

/// The latency HUD's input rows (p04-input-009): a reader on the input feed only while the HUD is
/// shown, the newest 16 events first with their longest stage interval, the ones over one 120 Hz
/// frame in the danger color, in catalog words (not enum case names), stale rows dropped on a new
/// show, both readers stopped by the title bar button, and no input section without a feed. Run:
/// `swift test --filter ActionLatencyHUDInputTests`.
@MainActor
@Suite struct ActionLatencyHUDInputTests {
    private static let ms: UInt64 = 1_000_000

    /// A feed that counts its readers and reports each reader's end.
    private final class CountingFeed: InputLatencyFeed {
        let subscriptions = Atomic<Int>(0)
        let lastReplayCount = Atomic<Int>(-1)
        let ended: AsyncStream<Void>
        private let endedContinuation: AsyncStream<Void>.Continuation

        init() {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            ended = stream
            endedContinuation = continuation
        }

        func closedSlots(replaying count: Int) -> AsyncStream<InputLatencySlot> {
            subscriptions.add(1, ordering: .relaxed)
            lastReplayCount.store(count, ordering: .relaxed)
            let (stream, continuation) = AsyncStream<InputLatencySlot>.makeStream()
            let ended = endedContinuation
            continuation.onTermination = { _ in ended.yield() }
            return stream
        }
    }

    private static func key(generated: UInt64, dispatchEnd: UInt64, presented: UInt64, target: InputTarget = .terminal) -> InputLatencySlot {
        var slot = InputLatencySlot(kind: .keyPress, target: target, entrypoint: .person, causedFrameUpdate: true)
        slot.generated = generated
        slot.dispatchEnd = dispatchEnd
        slot.presented = presented
        return slot
    }

    private static func color(of needle: String, in text: NSAttributedString) -> NSColor? {
        let range = (text.string as NSString).range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    @Test func theHUDReadsTheFeedOnlyWhileShown() async {
        let feed = CountingFeed()
        let hud = ActionLatencyHUD(monitor: ActionBudgetMonitor(), inputs: feed)
        #expect(feed.subscriptions.load(ordering: .relaxed) == 0, "a hidden HUD subscribed")
        #expect(!hud.isReadingInputs)

        hud.show(over: nil)
        #expect(feed.subscriptions.load(ordering: .relaxed) == 1)
        #expect(feed.lastReplayCount.load(ordering: .relaxed) == ActionLatencyHUD.rowCount)
        #expect(hud.isReadingInputs && hud.isReadingRuns)
        hud.show(over: nil)
        #expect(feed.subscriptions.load(ordering: .relaxed) == 1, "a second show added a reader")

        hud.hide()
        #expect(!hud.isReadingInputs && !hud.isReadingRuns)
        var ends = feed.ended.makeAsyncIterator()
        // The feed's stream ends when hide cancels its reader (event-driven: onTermination).
        #expect(await ends.next() != nil)

        hud.toggle(over: nil)
        #expect(feed.subscriptions.load(ordering: .relaxed) == 2)
        hud.toggle(over: nil)
        #expect(!hud.isReadingInputs)
        #expect(await ends.next() != nil)
    }

    @Test func theHUDShowsTheNewestInputsFirstWithTheirLongestStage() {
        let hud = ActionLatencyHUD(monitor: ActionBudgetMonitor(), inputs: CountingFeed())
        hud.show(over: nil)
        defer { hud.hide() }
        #expect(hud.text.string.contains("No input yet"))

        for index in 0..<(ActionLatencyHUD.rowCount + 4) {
            let start = UInt64(index + 1) * 100 * Self.ms
            hud.addInput(Self.key(generated: start, dispatchEnd: start + Self.ms, presented: start + 3 * Self.ms))
        }
        #expect(hud.inputRows.count == ActionLatencyHUD.rowCount)
        #expect(hud.inputRows.first?.slot.generated == UInt64(ActionLatencyHUD.rowCount + 4) * 100 * Self.ms)
        #expect(hud.inputRows.first?.dominant == InputLatencyDominantStage(from: .dispatchEnd, to: .presented, nanos: 2 * Self.ms))
        #expect(hud.text.string.contains("key down  terminal  longest dispatch end to presented"))
        #expect(!hud.text.string.contains("keyPress"), "an enum case name reached the panel")
    }

    @Test func anInputOverOneFrameIsInTheDangerColor() {
        let hud = ActionLatencyHUD(monitor: ActionBudgetMonitor(), inputs: CountingFeed())
        hud.show(over: nil)
        defer { hud.hide() }
        hud.addInput(Self.key(generated: 100 * Self.ms, dispatchEnd: 101 * Self.ms, presented: 103 * Self.ms, target: .sidebar))
        hud.addInput(Self.key(generated: 200 * Self.ms, dispatchEnd: 215 * Self.ms, presented: 220 * Self.ms, target: .chromiumPage))
        var unpresented = InputLatencySlot(kind: .mousePress, target: .palette, entrypoint: .person)
        unpresented.generated = 300 * Self.ms
        hud.addInput(unpresented)

        let text = hud.text
        let fast = Self.color(of: "sidebar", in: text)
        let slow = Self.color(of: "Chromium page", in: text)
        let unknown = Self.color(of: "palette", in: text)
        #expect(fast != nil && slow != nil && unknown != nil)
        #expect(slow != fast, "the input over 8.3 ms is not marked")
        #expect(unknown != slow, "an input with no presented frame is marked as slow")
    }

    @Test func aHUDShownAgainDropsTheRowsItKeptWhileHidden() {
        let hud = ActionLatencyHUD(monitor: ActionBudgetMonitor(), inputs: CountingFeed())
        hud.show(over: nil)
        hud.hide()
        hud.addInput(Self.key(generated: 100 * Self.ms, dispatchEnd: 101 * Self.ms, presented: 103 * Self.ms))
        hud.hide()
        hud.show(over: nil)
        defer { hud.hide() }
        #expect(hud.inputRows.isEmpty, "the feed's replay fills the rows, not the last session")
        #expect(hud.text.string.contains("No input yet"))
    }

    @Test func closingThePanelWithItsButtonStopsBothReaders() async {
        let feed = CountingFeed()
        let hud = ActionLatencyHUD(monitor: ActionBudgetMonitor(), inputs: feed)
        hud.show(over: nil)
        #expect(hud.isReadingInputs && hud.isReadingRuns)
        var ends = feed.ended.makeAsyncIterator()

        hud.window?.performClose(nil)
        #expect(!hud.isShown)
        #expect(!hud.isReadingInputs && !hud.isReadingRuns, "the title bar button left a reader running")
        #expect(await ends.next() != nil)
    }

    @Test func theHUDIsOneReaderOfTheAppFeed() {
        let feed = InputLatencySlotFeed()
        let hud = ActionLatencyHUD(monitor: ActionBudgetMonitor(), inputs: feed)
        #expect(feed.readerCount == 0)
        hud.show(over: nil)
        hud.show(over: nil)
        defer { hud.hide() }
        #expect(feed.readerCount == 1)
    }

    @Test func theCaptureSceneInputsShowOneFastOneSlowAndOneUnpresented() {
        let feed = InputLatencySlotFeed()
        for slot in ActionLatencyHUD.captureInputs { feed.publish(slot) }
        let hud = ActionLatencyHUD(monitor: ActionBudgetMonitor(), inputs: feed)
        for slot in feed.recentSlots(ActionLatencyHUD.rowCount) { hud.addInput(slot) }
        let totals = hud.inputRows.map(\.slot.totalNanos)
        #expect(totals.count == 3)
        #expect(totals[0] == nil, "the newest, the sidebar click, has no presented frame")
        #expect((totals[1] ?? 0) > ActionLatencyHUD.inputBudgetNanos)
        #expect((totals[2] ?? .max) < ActionLatencyHUD.inputBudgetNanos)
    }

    @Test func noFeedShowsNoInputSection() {
        let hud = ActionLatencyHUD(monitor: ActionBudgetMonitor())
        hud.show(over: nil)
        defer { hud.hide() }
        #expect(!hud.isReadingInputs)
        #expect(!hud.text.string.contains("No input yet"))
    }
}
