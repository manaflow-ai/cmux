public import CoreGraphics
public import Foundation

/// Live, cached pictures of panes for every card that shows one (a tab's hover card, the sidebar
/// workspace card's split miniature, an agent chat's tab link card). Each tab, at each picture size
/// a card asks for, has one Rust schedule (``RustPanePictureSchedule``) that says when its picture
/// must be captured again: only after its content changed (a terminal's output, a page's paint
/// version), at once on the first change after a quiet spell, then at most once per gap (200 ms a
/// terminal, 500 ms a page), one capture in flight. While nothing changed, a card that opens again
/// draws the kept picture with no capture at all. This class only passes the clock, captures and
/// keeps the pictures.
///
/// Off unless `CMUX_NEXT_PANE_PICTURES=1` (merge default-off), and off in a build whose pinned app
/// FFI predates the schedule: then every card captures as before.
public final class PanePictures {
    /// What a tab is, for its gap.
    public enum Kind: Sendable {
        case terminal
        case page
    }

    /// Whether the schedule drives the pictures (`CMUX_NEXT_PANE_PICTURES=1` and a linked schedule).
    public static let isEnabled = RustPanePictureSchedule.isLinked
        && ProcessInfo.processInfo.environment["CMUX_NEXT_PANE_PICTURES"] == "1"

    /// A request this long after the previous one for the same picture is a new watch (a card opened
    /// again): the schedule forgets "nothing to picture" and may capture once more.
    static let watchSpanMs: UInt64 = 2_000
    /// The longest a request waits for its due time (the trailing capture of a burst) instead of
    /// drawing the kept picture.
    static let waitForDueMs: UInt64 = 600

    private final class Slot {
        let schedule: any PanePictureScheduling
        /// The content stamp the schedule last saw (a terminal's change count, a page's version).
        var stamp: UInt64?
        var picture: CGImage?
        var lastAsked: UInt64?
        /// When the schedule last said a capture may start (its latest note or finish reply).
        var due: UInt64?

        init(schedule: any PanePictureScheduling) { self.schedule = schedule }
    }

    /// At most this many pictures are kept, least recently asked first out.
    public let capacity: Int
    private var slots: [String: Slot] = [:]
    private var order: [String] = []
    private let makeSchedule: @MainActor (Kind) -> (any PanePictureScheduling)?
    private let now: @MainActor () -> UInt64
    private let sleep: @MainActor (UInt64) async -> Void

    /// - Parameters:
    ///   - makeSchedule: a tab's new schedule; nil leaves it unscheduled (captured on every ask).
    ///   - now: monotonic milliseconds.
    ///   - sleep: waits that many milliseconds.
    public init(capacity: Int = 48,
                makeSchedule: @escaping @MainActor (Kind) -> (any PanePictureScheduling)? = PanePictures.rustSchedule,
                now: @escaping @MainActor () -> UInt64 = PanePictures.monotonicMs,
                sleep: @escaping @MainActor (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0 * 1_000_000) }) {
        self.capacity = capacity
        self.makeSchedule = makeSchedule
        self.now = now
        self.sleep = sleep
    }

    public static func rustSchedule(_ kind: Kind) -> (any PanePictureScheduling)? {
        RustPanePictureSchedule(gapMs: kind == .terminal ? RustPanePictureSchedule.terminalGapMs : RustPanePictureSchedule.pageGapMs)
    }

    public static func monotonicMs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

    /// The number of pictures kept.
    public var count: Int { slots.values.filter { $0.picture != nil }.count }

    /// `tab`'s picture for a card: with ``isEnabled``, a live terminal's (`terminalChanges`, its change count) or a
    /// live page's (`pageVersion`, its picture version) through its schedule; else, or for any other tab, `capture`.
    public func picture(_ tab: String, terminalChanges: UInt64?, pageVersion: Int?, maxPixelSize: CGSize,
                        capture: () async -> CGImage?) async -> CGImage? {
        guard Self.isEnabled else { return await capture() }
        if let terminalChanges { return await picture(tab, kind: .terminal, stamp: terminalChanges, maxPixelSize: maxPixelSize, capture: capture) }
        guard let pageVersion else { return await capture() }
        return await picture(tab, kind: .page, stamp: UInt64(truncatingIfNeeded: pageVersion), maxPixelSize: maxPixelSize, capture: capture)
    }

    /// `tab`'s picture at `maxPixelSize`: the kept one while it shows the current content, else a new
    /// `capture` when the schedule says one is due (waiting up to ``waitForDueMs`` for it), else the
    /// kept one. `stamp` is the tab's content stamp (any change means damage; nil: unknown, no damage).
    /// `capture` returns nil when there is nothing to picture now (a hibernated tab with no surface, a frame the system
    /// purged): the kept picture stays and is drawn, never an empty tile.
    public func picture(_ tab: String, kind: Kind, stamp: UInt64?, maxPixelSize: CGSize,
                        capture: () async -> CGImage?) async -> CGImage? {
        let key = "\(tab)@\(Int(max(maxPixelSize.width, maxPixelSize.height).rounded()))"
        guard let slot = slot(key, kind: kind) else { return await capture() }
        let schedule = slot.schedule
        let asked = now()
        if slot.lastAsked.map({ asked &- $0 > Self.watchSpanMs }) ?? true { slot.due = schedule.note(.watched, now: asked) }
        slot.lastAsked = asked
        if let stamp, stamp != slot.stamp {
            if slot.stamp != nil { slot.due = schedule.note(.damaged, now: asked) }
            slot.stamp = stamp
        }
        if schedule.isCurrent, let picture = slot.picture { return picture }
        var generation = schedule.takeDue(now: asked)
        if generation == nil, let due = slot.due, due > asked, due - asked <= Self.waitForDueMs {
            await sleep(due - asked)
            generation = schedule.takeDue(now: now())
        }
        guard let generation else { return slot.picture }
        slot.due = nil
        let image = await capture()
        slot.due = schedule.finish(generation, image == nil ? .unavailable : .done, now: now())
        if let image { slot.picture = image }
        return image ?? slot.picture
    }

    /// Forgets `tab`'s pictures and schedules (the tab closed).
    public func forget(_ tab: String) {
        let prefix = "\(tab)@"
        for key in slots.keys where key.hasPrefix(prefix) { slots[key] = nil }
        order.removeAll { $0.hasPrefix(prefix) }
    }

    private func slot(_ key: String, kind: Kind) -> Slot? {
        if let slot = slots[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return slot
        }
        guard let schedule = makeSchedule(kind) else { return nil }
        let slot = Slot(schedule: schedule)
        slots[key] = slot
        order.append(key)
        while order.count > capacity { slots[order.removeFirst()] = nil }
        return slot
    }
}
