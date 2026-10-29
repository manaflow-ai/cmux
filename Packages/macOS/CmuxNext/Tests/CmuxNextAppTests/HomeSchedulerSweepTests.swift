import AppKit
import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextWakeups
import Foundation
import Testing

extension HomeRecipientPictures {
    /// Pictures for a test's New Message list: reads on a lane of their own, replies on a scheduler with no link.
    static func testing() -> HomeRecipientPictures {
        HomeRecipientPictures(work: BackgroundWork(label: "test.home-recipient-pictures"), mainWork: linklessMainWork())
    }
}

/// The CmuxNextHome sweep (plans/cmux-next/chrome-parity/p06-scheduler.md rule 9): one case per
/// migrated owner class. The avatar read's reply is a `visible` task the scheduler names; the transcript's engine
/// wakes are a `visible` MainDeadline that aligns while hidden; its window notices reach a hidden transcript (read
/// receipts are a model change); and its visibility, its theme repaint and `shown(in:)` follow its node, not an
/// ancestor walk.
@MainActor @Suite(.serialized) struct HomeSchedulerSweepTests {
    // MARK: R-hop: the avatar read lands as one posted visible task

    @Test func anAvatarReadLandsAsOneVisibleTaskOnTheScheduler() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("home-avatars-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("chief.png")
        try Self.png(side: 8).write(to: url)
        let board = MainTaskBoard(ledger: MainOwnerLedger(capacity: 64, folding: .manual))
        let pictures = HomeRecipientPictures(work: BackgroundWork(label: "test.home-avatar-read"),
                                             mainWork: MainWorkScheduler(budget: MainFrameBudget(board: board)))
        let shown = Seen<NSImage?>(nil)
        pictures.read(url) { shown.value = $0 }
        #expect(shown.value == nil, "the read answered in the caller's turn: it ran on the main thread")
        #expect(runMainLoop { shown.value != nil }, "the read never landed")
        #expect(pictures.picture(url) === shown.value, "the list did not keep the picture it read")
        let row = try #require(board.ownerSnapshot().owners.first { $0.owner == HomeRecipientPictures.owner },
                               "the read landed outside the scheduler: no owner row")
        #expect(row.workClass == .visible)
        #expect(row.tasks == 1, "one read landed as \(row.tasks) tasks")
        #expect(row.sites.first?.location.contains("HomeRecipientAvatarView.swift") == true, "\(row.sites)")
    }

    // MARK: R-timer: the engine's wakes are a visible MainDeadline aligned while hidden

    @Test func theTranscriptsEngineWakeIsAVisibleDeadlineThatAlignsWhileHidden() {
        let rig = MainDeadlineRig()
        let node = VisibilityNode(root: "test.home.transcript", own: .visible)
        let wake = HomeDemandWake(node: node, deadlines: rig.deadlines)
        #expect(wake.deadline.workClass == .visible)
        let fired = Seen(0)
        wake.schedule(after: 0.3) { fired.value += 1 }
        #expect(wake.deadline.plannedWake?.rule == .flexible, "a shown transcript's wake moved off its leeway window")
        rig.fireAndRun()
        #expect(fired.value == 1)

        node.set(.hidden)
        wake.schedule(after: 0.3) { fired.value += 1 }
        #expect(wake.deadline.plannedWake?.rule == .hidden, "a hidden transcript's wake is not aligned to the second")
        wake.cancel()
        #expect(!wake.deadline.isScheduled)
        rig.fireAndRun()
        #expect(fired.value == 1, "a cancelled wake ran")
    }

    // MARK: R-notif: the window's key notices reach a hidden transcript (always)

    @Test func aHiddenTranscriptStillFollowsItsWindowsKeyStateThroughOneFanOut() {
        let view = Self.transcript()
        let window = KeyedWindow.make()
        defer { window.close() }
        // The window's one fan-out, made first on the test's own center: the transcript's `WindowEvents.of` finds it.
        let center = NotificationCenter()
        let events = WindowEvents.of(window, center: center)
        let tab = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        window.contentView?.addSubview(tab)
        view.frame = tab.bounds
        tab.addSubview(view)
        #expect(events.subscriberCount(NSWindow.didBecomeKeyNotification) == 1)
        #expect(events.subscriberCount(NSWindow.didChangeOcclusionStateNotification) == 1)
        #expect(!view.transcript.isVisibleToUser)

        tab.isHidden = true
        window.key = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(view.transcript.isVisibleToUser, "a hidden transcript missed its window becoming key (read receipts)")

        view.removeFromSuperview()
        #expect(events.subscriberCount(NSWindow.didBecomeKeyNotification) == 0, "a transcript out of the window kept its subscription")
        view.stop()
    }

    // MARK: R-vis, R-hide, R-appear: the node, not an ancestor walk

    @Test func aParkedTranscriptIsNotShownAndRepaintsOnceWhenItShowsAgain() {
        let view = Self.transcript()
        let window = KeyedWindow.make()
        defer { window.close() }
        let tab = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        window.contentView?.addSubview(tab)
        view.frame = tab.bounds
        tab.addSubview(view)
        #expect(view.visibility.isVisible)
        #expect(HomeNativeTranscriptView.shown(in: window) === view)

        tab.isHidden = true
        #expect(!view.visibility.isVisible, "an ancestor's hide did not reach the transcript's node")
        #expect(HomeNativeTranscriptView.shown(in: window) == nil, "a parked transcript counts as shown")
        view.viewDidChangeEffectiveAppearance()
        view.viewDidChangeEffectiveAppearance()
        #expect(view.visibility.deferredCount == 1, "a parked transcript repainted, or queued more than one repaint")

        tab.isHidden = false
        #expect(view.visibility.deferredCount == 0, "showing the transcript did not run its repaint")
        #expect(HomeNativeTranscriptView.shown(in: window) === view)

        view.stop()
        #expect(!view.visibility.isVisible, "a stopped transcript stays visible")
        #expect(HomeNativeTranscriptView.shown(in: window) == nil)
    }

    // MARK: Helpers

    private static func transcript() -> HomeNativeTranscriptView {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(HomeTunables.all)
        return HomeNativeTranscriptView(store: HomeStore(source: MockHomeSource(options: .immediate)),
                                        conversation: ConversationID("conv_sweep"), me: ParticipantID("user_me"),
                                        deadlines: linklessDeadlines())
    }

    private static func png(side: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}

/// A window whose key state the test sets (a test process has no key window).
private final class KeyedWindow: NSWindow {
    var key = false

    static func make() -> KeyedWindow {
        let window = KeyedWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    override var isKeyWindow: Bool { key }
    override var occlusionState: NSWindow.OcclusionState { .visible }
}

/// What a main-actor callback saw (its closures are `@Sendable`, so they cannot write a local).
private final class Seen<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }

    nonisolated deinit {}
}
