import AppKit
import CmuxNextCompat
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextWakeups
import CmuxScreenKit
import Foundation
import Testing

/// Mac Screen's owners on the scheduler (plans/cmux-next/chrome-parity/p06-scheduler.md, rule 9):
/// app notices through the app's one observer per name, hidden views repaint once on show, deadlines carry a class,
/// and side effects still run while nothing shows.
@MainActor
struct MacScreenSchedulerSweepTests {
    private static let deviceID = "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff"

    private final class Counter {
        var value = 0
    }

    /// A count the permission checks (`@Sendable`, run on the system lane) can bump.
    private nonisolated final class SendableCounter: Sendable {
        private let count = Mutex(0)
        func increment() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    /// Calls in order (a class: actor-isolated closures cannot capture a mutable local).
    @MainActor
    private final class Log {
        var items: [String] = []
    }

    /// Audit reads that wait until the test lets them end.
    @MainActor
    private final class HeldAuditReads {
        var calls = 0
        private var held: [AsyncStream<Void>.Continuation] = []

        func read() async {
            calls += 1
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            held.append(continuation)
            for await _ in stream {}
        }

        func releaseAll() {
            let all = held
            held = []
            for continuation in all { continuation.finish() }
        }
    }

    /// Yields to the main actor's other jobs until `done` holds (at most 500 times); returns `done()`.
    private static func settle(_ done: () -> Bool) async -> Bool {
        for _ in 0..<500 where !done() { await Task.yield() }
        return done()
    }

    /// Runs up to `count` frames, each after the main actor's other jobs ran, until `done` holds; returns `done()`.
    private static func frames(_ rig: MainDeadlineRig, count: Int = 200, until done: () -> Bool) async -> Bool {
        for _ in 0..<count where !done() {
            for _ in 0..<10 { await Task.yield() }
            rig.frame()
        }
        return done()
    }

    private static func pages(_ deadlines: MainDeadlineScheduler, events: AppEvents) -> MacScreenPages {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        return MacScreenPages(store: MacScreenStore(file: file, runner: BackgroundWork(label: "test.mac-screen"), removeLinkPairings: {}), deadlines: deadlines, appEvents: events, work: BackgroundWork())
    }

    /// R-appear: a theme change while the view is hidden repaints nothing until it shows, then once.
    @Test func aHiddenViewRepaintsAThemeChangeOnceOnShow() {
        let node = VisibilityNode(root: "test.mac-screen.tab", own: .hidden)
        let view = MacScreenThemedView(frame: .zero, node: node)
        view.viewDidChangeEffectiveAppearance()
        view.viewDidChangeEffectiveAppearance()
        #expect(node.deferredCount == 1, "a hidden view's theme changes did not wait as one repaint")
        node.set(.visible)
        #expect(node.deferredCount == 0, "the show did not repaint")
        view.viewDidChangeEffectiveAppearance()
        #expect(node.deferredCount == 0, "a shown view's theme change waited")
    }

    /// R-hide: the tab's shown state is its node's, forwarded from AppKit's hidden state and its window.
    @Test func theTabsNodeFollowsItsWindowAndItsHiddenState() {
        let view = MacScreenTabView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [], backing: .buffered, defer: true)
        let parent = NSView(frame: window.contentLayoutRect)
        window.contentView = parent
        #expect(!view.node.isVisible, "a tab in no window read visible")
        parent.addSubview(view)
        #expect(view.node.isVisible)
        parent.isHidden = true
        #expect(view.node.effective == .hidden, "a hidden ancestor did not hide the tab's node")
        parent.isHidden = false
        #expect(view.node.isVisible)
        view.removeFromSuperview()
        #expect(!view.node.isVisible, "a tab out of its window read visible")
    }

    /// R-notif, side effect while hidden: the permissions are read again on the app's activation notice, with no
    /// node (a permission granted in System Settings counts whatever shows). Each read runs on the system lane
    /// (`MacScreenShareHost.refreshPermissions`): every read signals `done`, and the test awaits exactly the reads it
    /// expects (no wall-clock wait; the time limit only catches a read that never comes).
    @Test(.timeLimit(.minutes(1))) func thePermissionsAreReadAgainOnTheAppsOneActivationObserver() async {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let host = MacScreenShareHost(work: BackgroundWork())
        let reads = SendableCounter()
        let done = AsyncStream<Void>.makeStream()
        host.checkScreenRecording = { reads.increment(); done.continuation.yield(); return false }
        host.checkAccessibility = { false }
        var landed = done.stream.makeAsyncIterator()
        host.activate(events: events)
        host.activate(events: events)
        await landed.next()
        await landed.next()
        #expect(reads.value == 2)
        #expect(events.subscriberCount(NSApplication.didBecomeActiveNotification) == 1, "activate subscribed twice")
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await landed.next()
        #expect(reads.value == 3, "the activation notice did not read the permissions again")
    }

    /// R-notif: the system shortcut tap follows the app's and the key windows' notices through one subscription each,
    /// and quitting ends the sessions through the app's one quit observer.
    @Test func theTapAndTheQuitFollowTheAppsNotices() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let pages = Self.pages(linklessDeadlines(), events: events)
        #expect(events.subscriberCount(NSApplication.willTerminateNotification) == 1)
        let checks = Counter()
        pages.systemShortcuts.isAppActive = { checks.value += 1; return false }
        pages.systemShortcuts.checkAccessibility = { false }
        pages.systemShortcuts.start()
        pages.systemShortcuts.start()
        let names = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        for name in names {
            #expect(events.subscriberCount(name) == 1, "\(name.rawValue)")
        }
        let before = checks.value
        for name in names { center.post(name: name, object: nil) }
        #expect(checks.value == before + names.count, "a notice did not update the tap")
    }

    /// R-timer: a hidden device tab ends its session after the grace as one background deadline, on the scheduler's
    /// queue, and showing it asks again for the same scope.
    @Test func aHiddenDeviceTabEndsItsSessionAfterTheGraceAsABackgroundDeadline() {
        let rig = MainDeadlineRig()
        let node = VisibilityNode(root: "test.mac-screen.tab", own: .visible)
        let viewer = MacScreenHubViewer(deviceID: Self.deviceID, deadlines: rig.deadlines) { nil }
        viewer.endSession = { _, _, _ in }
        let pane = MacScreenPane(hubDevice: viewer, name: "Studio", preferences: ScreenPreferences(), node: node, on: rig.work)
        defer { pane.close() }
        pane.resume()
        viewer.phase = .streaming(sessionID: "s1", scope: .full)
        node.set(.hidden)
        pane.pause()
        #expect(rig.hasArmedWake, "the hidden grace armed no deadline")
        rig.frame()
        #expect(viewer.phase == .streaming(sessionID: "s1", scope: .full), "the session ended before its grace")
        rig.fireAndRun()
        #expect(viewer.phase == .idle)
        #expect(viewer.resumeScope == .full, "showing the tab would not ask again")
    }

    /// R-hop: a restored device tab is retitled in one visible task, not in the restore's turn.
    @Test func aRestoredDeviceTabIsRetitledInOneVisibleTask() {
        let rig = MainDeadlineRig()
        let pages = Self.pages(rig.deadlines, events: AppEvents(center: NotificationCenter()))
        let titled = Counter()
        pages.events.titleChanged = { _ in titled.value += 1 }
        pages.restore("device:\(Self.deviceID)", for: "tab")
        #expect(titled.value == 0, "the retitle ran in the restore's turn")
        #expect(rig.work.postedCount(.visible) == 1)
        rig.frame()
        #expect(titled.value == 1)
    }

    /// R-hop: a Cancel that comes after the request's HTTP answer but before its posted userBlocking task still
    /// reads as a cancel there, so the session the request made ends (the host's prompt goes away).
    @Test func aCancelBeforeTheAnswersPostedTaskEndsTheSessionItMade() async {
        let rig = MainDeadlineRig()
        let hub = testHub()
        let viewer = MacScreenHubViewer(deviceID: Self.deviceID, deadlines: rig.deadlines) { hub }
        let ends = Log()
        viewer.endSession = { _, id, reason in ends.items.append("\(id) \(reason)") }
        viewer.askSession = { _, _, scope in HubSession(id: "s1", state: .pending, scope: scope) }
        viewer.request(.view)
        #expect(await Self.settle { rig.work.postedCount(.userBlocking) == 1 }, "the answer never reached its posted task")
        viewer.cancel()
        rig.frame()
        #expect(await Self.settle { !ends.items.isEmpty })
        #expect(ends.items == ["s1 viewer_disconnected"])
        #expect(viewer.phase == .idle)
    }

    /// R-hop: a new request that comes before the older answer's posted task never takes that answer: the older
    /// session ends, and the newer answer is the one the card shows.
    @Test func aNewRequestNeverTakesTheOlderAnswer() async {
        let rig = MainDeadlineRig()
        let hub = testHub()
        let viewer = MacScreenHubViewer(deviceID: Self.deviceID, deadlines: rig.deadlines) { hub }
        let ends = Log()
        viewer.endSession = { _, id, reason in ends.items.append("\(id) \(reason)") }
        let asked = Log()
        viewer.askSession = { _, _, scope in
            asked.items.append("\(scope)")
            return HubSession(id: "s\(asked.items.count)", state: .pending, scope: scope)
        }
        viewer.request(.view)
        #expect(await Self.settle { rig.work.postedCount(.userBlocking) == 1 })
        viewer.request(.full)
        #expect(await Self.settle { rig.work.postedCount(.userBlocking) == 2 })
        #expect(await Self.frames(rig) { !ends.items.isEmpty && rig.work.postedCount(.userBlocking) == 0 })
        #expect(ends.items == ["s1 viewer_disconnected"])
        #expect(viewer.phase == .waitingForApproval(sessionID: "s2", scope: .full))
        viewer.cancel()
    }

    /// R-hop: pushes during a held audit read start one more read after it, never one per push, and none once the
    /// last Settings card closed.
    @Test func pushesDuringAHeldAuditReadReadOnceMoreAndNoneAfterTheCardCloses() async {
        let rig = MainDeadlineRig()
        let pages = Self.pages(rig.deadlines, events: AppEvents(center: NotificationCenter()))
        pages.hub = testHub()
        let settings = MacScreenDevicesSettings(pages: pages)
        let reads = HeldAuditReads()
        settings.refreshAudit = { _ in await reads.read() }
        settings.beginWatching()
        #expect(await Self.settle { reads.calls == 1 }, "showing the card read no audit")
        settings.readAudit()
        settings.readAudit()
        reads.releaseAll()
        #expect(await Self.frames(rig) { reads.calls == 2 }, "the pushes during the read read nothing after it")
        // Two more pushes during the second read, then the card closes: no read follows.
        settings.readAudit()
        settings.readAudit()
        settings.endWatching()
        reads.releaseAll()
        _ = await Self.frames(rig, count: 50) { false }
        #expect(reads.calls == 2, "an audit read ran after the last card closed")
    }
}
