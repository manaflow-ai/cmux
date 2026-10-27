import AppKit
import CmuxNextWakeups
import Darwin
public import Foundation
import os

/// A second copy's hand-off (``SingleInstanceGuard``): a plain `NSApplication` that takes this launch's open
/// events, sends them to the claim owner's pid, brings the owner forward, and exits. It never makes
/// `CmuxApplication`, a window, a session, the daemon connection or CEF.
///
/// Events go to the owner's pid (read from the claim, ``SingleInstanceGuard/owner(at:)``), never through
/// LaunchServices by app URL: both copies run from the same bundle, so an open by URL could come back here. Each
/// event waits for the owner's reply (its handler ran); one that is not answered stays pending and is sent again
/// until ``deadline``. If the owner is gone with events still pending (it quit in between), this launch reopens
/// through LaunchServices with them once this process has exited. An agent launch (`CMUX_NEXT_NO_ACTIVATE=1`)
/// forwards nothing: any open would bring the owner forward.
///
/// Stop conditions: it exits ``settle`` after the last event it took once nothing is pending (open events AppKit
/// delivers after `applicationDidFinishLaunching` still go), at ``deadline`` from a main-actor task, and at
/// ``hardDeadline`` from a timer off the main thread, so a blocked send cannot hold it.
@MainActor final class SingleInstanceHandoff: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "launch")
    nonisolated static let settle: Duration = .milliseconds(300)
    nonisolated static let retry: Duration = .milliseconds(250)
    /// From the start of the hand-off (before AppKit starts): when unanswered work is given up (or reopened).
    nonisolated static let deadline: TimeInterval = 4
    /// From the same start: the process ends, whatever happens. Leaves the recovery after ``deadline`` its time.
    nonisolated static let hardDeadline: TimeInterval = 6
    /// The longest one event waits for its reply.
    nonisolated static let replyWait: TimeInterval = 1

    private let lock: URL
    /// ``deadline`` after the hand-off started (`run`, before AppKit): an absolute instant, so neither AppKit's
    /// start nor a slow first batch moves it.
    private let giveUpAt: ContinuousClock.Instant
    private var queue = SingleInstanceHandoffQueue()
    private var launched = false
    /// The next step: the settle before exiting, or the next try.
    private let step = DemandTimer(owner: "SingleInstanceHandoff.step")
    /// ``deadline``: unanswered work is given up (or reopened).
    private let giveUpTimer = DemandTimer(owner: "SingleInstanceHandoff.giveUp")

    private init(lock: URL, giveUpAt: ContinuousClock.Instant) {
        self.lock = lock
        self.giveUpAt = giveUpAt
    }

    /// Runs the hand-off to the owner of `lock`; never returns.
    static func run(lock: URL, activates: Bool) -> Never {
        let giveUpAt = ContinuousClock.now + .seconds(deadline)
        logger.notice("launch: another copy of this app holds \(lock.path, privacy: .public); handing off and exiting before Chromium or the session start")
        guard activates else {
            logger.notice("launch: an agent launch of a second copy forwards nothing (the running copy would come forward); exiting")
            exit(0)
        }
        // ``hardDeadline``: the process ends. Its sleep runs off the main thread, so a blocked send cannot hold it;
        // `run` never returns, so the timer lives until the exit.
        let hardExit = DemandTimer(owner: "SingleInstanceHandoff.hardExit")
        hardExit.schedule(after: .seconds(hardDeadline)) { exit(0) }
        // No saved windows of this copy: its restoration store would take over the running copy's.
        UserDefaults.standard.setVolatileDomain(["ApplePersistenceIgnoreState": true], forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        // No Dock icon; an accessory may still be active, so it can hand activation to the owner.
        app.setActivationPolicy(.accessory)
        let handoff = SingleInstanceHandoff(lock: lock, giveUpAt: giveUpAt)
        app.delegate = handoff
        withExtendedLifetime((handoff, hardExit)) { app.run() }
        exit(0)
    }

    /// This launch's documents and URLs (AppKit routes both `odoc` and `GURL` here).
    func application(_ application: NSApplication, open urls: [URL]) {
        queue.add(urls)
        if launched { attempt() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        // The timer's sleep starts now, off the main thread, so a slow first batch does not move it.
        giveUpTimer.schedule(after: ContinuousClock.now.duration(to: giveUpAt)) { @MainActor [weak self] in self?.giveUp() }
        attempt()
    }

    /// Sends what is pending, each event dropped once answered; then exits after the settle time, or tries again.
    private func attempt() {
        step.cancel()
        let owner = SingleInstanceGuard.owner(at: lock)
        if let owner {
            let before = queue.pending.count
            let giveUpAt = giveUpAt
            queue.drain { [self] event in
                guard let wait = Self.replyBudget(now: .now, giveUpAt: giveUpAt) else { return .notDelivered }
                return send(event, to: owner, timeout: wait)
            }
            if queue.pending.count < before {
                Self.logger.notice("launch: \(before - self.queue.pending.count, privacy: .public) event(s) answered by pid \(owner, privacy: .public)")
            }
        }
        let done = queue.isDone
        step.schedule(after: done ? Self.settle : Self.retry) { @MainActor [weak self] in
            guard let self else { return }
            if done { self.finish(owner: owner) } else if ContinuousClock.now < self.giveUpAt { self.attempt() }
        }
    }

    /// How long the next event may wait for its reply: at most ``replyWait``, never past `giveUpAt`, and nil
    /// (send nothing) with under 50 ms left. So sends end by `giveUpAt`, and the recovery there keeps the time up
    /// to ``hardDeadline``.
    nonisolated static func replyBudget(now: ContinuousClock.Instant, giveUpAt: ContinuousClock.Instant) -> TimeInterval? {
        let left = now.duration(to: giveUpAt)
        guard left > .milliseconds(50) else { return nil }
        let seconds = Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
        return min(replyWait, seconds)
    }

    private func send(_ event: SingleInstanceHandoffEvents.Event, to owner: pid_t, timeout: TimeInterval) -> SingleInstanceHandoffQueue.Outcome {
        do {
            _ = try SingleInstanceHandoffEvents.descriptor(event, to: owner).sendEvent(options: [.waitForReply], timeout: timeout)
            return .answered
        } catch {
            let code = (error as NSError).code
            let delivered = SingleInstanceHandoffEvents.wasDelivered(errorCode: code)
            Self.logger.error("launch: hand-off event to pid \(owner, privacy: .public) failed (\(code, privacy: .public)); \(delivered ? "delivered, not sent again" : "not delivered, retried", privacy: .public)")
            return delivered ? .delivered : .notDelivered
        }
    }

    private func finish(owner: pid_t?) {
        // Delivered but never answered, and the owner is gone now: it may not have opened them.
        if !queue.unansweredURLs.isEmpty, SingleInstanceGuard.isFree(at: lock) {
            Self.logger.notice("launch: the running copy exited before answering; reopening this launch")
            Self.reopenAfterExit(bundle: Bundle.main.bundleURL, urls: queue.unansweredURLs)
            exit(0)
        }
        // Only a copy of this bundle: never another app that reused the pid.
        if let owner, let running = NSRunningApplication(processIdentifier: owner),
           running.bundleIdentifier == Bundle.main.bundleIdentifier {
            NSApp.yieldActivation(to: running)
            running.activate()
        }
        exit(0)
    }

    /// The deadline with events still unanswered. The owner ended (the claim is free): the launch reopens through
    /// LaunchServices, and that launch takes the claim as any other. Otherwise the rest is dropped, logged; the
    /// claim's descriptor is close-on-exec, so only a live copy of the app holds it, and it frees when that ends.
    private func giveUp() {
        guard !queue.isDone || !queue.unansweredURLs.isEmpty else { return }
        step.cancel()
        let urls = queue.unansweredURLs
        let owner = SingleInstanceGuard.owner(at: lock)
        if SingleInstanceGuard.isFree(at: lock) {
            Self.logger.notice("launch: the running copy exited during the hand-off; reopening this launch")
            Self.reopenAfterExit(bundle: Bundle.main.bundleURL, urls: urls)
        } else {
            Self.logger.error("launch: the running copy never answered; \(urls.count, privacy: .public) URL(s) not handed off")
        }
        exit(0)
    }

    /// `open -a <bundle> <urls>` from a child that waits on this process's exit (`caffeinate -w`, the kernel's
    /// exit event, as `RollbackSwap.relaunchCommand`), so LaunchServices starts a new copy instead of this one.
    private static func reopenAfterExit(bundle: URL, urls: [URL]) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "p=$0; shift; /usr/bin/caffeinate -w \"$p\"; exec /usr/bin/open \"$@\"",
                             String(getpid()), "-a", bundle.path] + urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
        do { try process.run() } catch {
            logger.error("launch: reopen failed: \(String(describing: error), privacy: .public)")
        }
    }
}

public extension SingleInstanceGuard {
    /// Hands this launch to the copy that owns `lock` and exits (``SingleInstanceHandoff``); never returns.
    @MainActor static func handOff(lock: URL, activates: Bool) -> Never {
        SingleInstanceHandoff.run(lock: lock, activates: activates)
    }
}

/// What a hand-off still has to send, in order. An event leaves the queue once the owner answered it, so a retry
/// never repeats an open the owner already did (each open makes a tab). A bare launch is one `rapp`, replaced by
/// the launch's URLs when any arrive before it was answered.
nonisolated struct SingleInstanceHandoffQueue: Equatable {
    /// What one send did.
    enum Outcome: Equatable {
        /// The owner's handler ran.
        case answered
        /// It reached the owner's queue but the reply timed out: never sent again (it may still run, and each open
        /// makes a tab), but kept for a reopen if the owner then exits.
        case delivered
        /// It never reached the owner: sent again.
        case notDelivered
    }

    private(set) var pending: [SingleInstanceHandoffEvents.Event] = [.reopen]
    /// Delivered without an answer.
    private(set) var unanswered: [SingleInstanceHandoffEvents.Event] = []

    var isDone: Bool { pending.isEmpty }

    mutating func add(_ urls: [URL]) {
        pending.removeAll { $0 == .reopen }
        pending += SingleInstanceHandoffEvents.events(for: urls)
    }

    /// Sends pending events in order; each answered or delivered one leaves; the first undelivered one stops the pass.
    mutating func drain(_ send: (SingleInstanceHandoffEvents.Event) -> Outcome) {
        while let event = pending.first {
            switch send(event) {
            case .answered: pending.removeFirst()
            case .delivered: unanswered.append(pending.removeFirst())
            case .notDelivered: return
            }
        }
    }

    /// The URLs the owner has not answered (pending or delivered), for a reopen through LaunchServices.
    var unansweredURLs: [URL] {
        (unanswered + pending).flatMap { event -> [URL] in
            switch event {
            case .openDocuments(let files): files
            case .getURL(let url): [url]
            case .reopen: []
            }
        }
    }
}

/// The Apple events a hand-off sends: files as one `odoc` and every other URL as its own `GURL`; a bare launch
/// sends a `rapp` (the Dock icon's click: the running copy shows a window if it has none).
nonisolated enum SingleInstanceHandoffEvents {
    enum Event: Equatable {
        case openDocuments([URL])
        case getURL(URL)
        case reopen
    }

    /// Whether a failed send still reached the owner: a reply timeout (`errAETimeout`) means the event was queued
    /// and may yet run, so sending it again could open a second tab. Anything else (no such process, an invalid
    /// connection, a refused event) did not deliver it.
    static func wasDelivered(errorCode: Int) -> Bool {
        errorCode == Int(errAETimeout)
    }

    static func events(for urls: [URL]) -> [Event] {
        let files = urls.filter(\.isFileURL)
        return (files.isEmpty ? [] : [.openDocuments(files)]) + urls.filter { !$0.isFileURL }.map(Event.getURL)
    }

    static func descriptor(_ event: Event, to pid: pid_t) -> NSAppleEventDescriptor {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        func make(_ eventClass: AEEventClass, _ eventID: AEEventID) -> NSAppleEventDescriptor {
            NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID, targetDescriptor: target,
                                   returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        }
        switch event {
        case .openDocuments(let files):
            let descriptor = make(AEEventClass(kCoreEventClass), AEEventID(kAEOpenDocuments))
            let list = NSAppleEventDescriptor.list()
            for file in files { list.insert(NSAppleEventDescriptor(fileURL: file), at: 0) }
            descriptor.setParam(list, forKeyword: AEKeyword(keyDirectObject))
            return descriptor
        case .getURL(let url):
            let descriptor = make(AEEventClass(kInternetEventClass), AEEventID(kAEGetURL))
            descriptor.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
            return descriptor
        case .reopen:
            return make(AEEventClass(kCoreEventClass), AEEventID(kAEReopenApplication))
        }
    }
}
