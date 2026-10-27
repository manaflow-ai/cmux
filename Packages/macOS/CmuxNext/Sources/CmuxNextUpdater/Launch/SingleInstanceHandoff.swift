import AppKit
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
    static let settle: Duration = .milliseconds(300)
    static let retry: Duration = .milliseconds(250)
    /// From the start of the hand-off (before AppKit starts): when unanswered work is given up (or reopened).
    static let deadline: TimeInterval = 4
    /// From the same start: the process ends, whatever happens. Leaves the recovery after ``deadline`` its time.
    static let hardDeadline: TimeInterval = 6
    /// The longest one event waits for its reply.
    static let replyWait: TimeInterval = 1

    private let lock: URL
    /// When the hand-off started (`run`), the base of both deadlines.
    private let start: Date
    private var queue = SingleInstanceHandoffQueue()
    private var launched = false
    private var finishing: Task<Void, Never>?

    private init(lock: URL, start: Date) {
        self.lock = lock
        self.start = start
    }

    /// Runs the hand-off to the owner of `lock`; never returns.
    static func run(lock: URL, activates: Bool) -> Never {
        let start = Date()
        logger.notice("launch: another copy of this app holds \(lock.path, privacy: .public); handing off and exiting before Chromium or the session start")
        guard activates else {
            logger.notice("launch: an agent launch of a second copy forwards nothing (the running copy would come forward); exiting")
            exit(0)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + hardDeadline) { exit(0) }
        // No saved windows of this copy: its restoration store would take over the running copy's.
        UserDefaults.standard.setVolatileDomain(["ApplePersistenceIgnoreState": true], forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        // No Dock icon; an accessory may still be active, so it can hand activation to the owner.
        app.setActivationPolicy(.accessory)
        let handoff = SingleInstanceHandoff(lock: lock, start: start)
        app.delegate = handoff
        withExtendedLifetime(handoff) { app.run() }
        exit(0)
    }

    private var remaining: TimeInterval { Self.deadline - Date().timeIntervalSince(start) }

    /// This launch's documents and URLs (AppKit routes both `odoc` and `GURL` here).
    func application(_ application: NSApplication, open urls: [URL]) {
        queue.add(urls)
        if launched { attempt() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        let wait = max(0, remaining)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            self?.giveUp()
        }
        attempt()
    }

    /// Sends what is pending, each event dropped once answered; then exits after the settle time, or tries again.
    private func attempt() {
        finishing?.cancel()
        let owner = SingleInstanceGuard.owner(at: lock)
        if let owner {
            let before = queue.pending.count
            queue.drain { [self] event in
                let wait = min(Self.replyWait, remaining)
                guard wait > 0.05 else { return false }
                return send(event, to: owner, timeout: wait)
            }
            if queue.pending.count < before {
                Self.logger.notice("launch: \(before - self.queue.pending.count, privacy: .public) event(s) answered by pid \(owner, privacy: .public)")
            }
        }
        let done = queue.isDone
        finishing = Task { [weak self] in
            try? await Task.sleep(for: done ? Self.settle : Self.retry)
            guard !Task.isCancelled, let self else { return }
            if done { self.finish(owner: owner) } else if self.remaining > 0 { self.attempt() }
        }
    }

    private func send(_ event: SingleInstanceHandoffEvents.Event, to owner: pid_t, timeout: TimeInterval) -> Bool {
        do {
            _ = try SingleInstanceHandoffEvents.descriptor(event, to: owner).sendEvent(options: [.waitForReply], timeout: timeout)
            return true
        } catch {
            Self.logger.error("launch: hand-off event to pid \(owner, privacy: .public) not answered: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func finish(owner: pid_t?) {
        if let owner, let running = NSRunningApplication(processIdentifier: owner) {
            NSApp.yieldActivation(to: running)
            running.activate()
        }
        exit(0)
    }

    /// The deadline with events still unanswered. The owner ended (the claim is free): the launch reopens through
    /// LaunchServices. The claim is held but its recorded owner is gone (a leaked descriptor, not a copy of the
    /// app): the launch reopens past the guard (`CMUX_NEXT_ALLOW_SECOND_INSTANCE=1`), so cmux never becomes
    /// unlaunchable. The owner is alive but never answered: the rest is dropped, logged.
    private func giveUp() {
        guard !queue.isDone else { return }
        finishing?.cancel()
        let urls = queue.unansweredURLs
        let owner = SingleInstanceGuard.owner(at: lock)
        if SingleInstanceGuard.isFree(at: lock) {
            Self.logger.notice("launch: the running copy exited during the hand-off; reopening this launch")
            Self.reopenAfterExit(bundle: Bundle.main.bundleURL, urls: urls, pastGuard: false)
        } else if let owner, kill(owner, 0) != 0, errno == ESRCH {
            Self.logger.error("launch: the claim is held but its owner pid \(owner, privacy: .public) is gone; reopening past the guard")
            Self.reopenAfterExit(bundle: Bundle.main.bundleURL, urls: urls, pastGuard: true)
        } else {
            Self.logger.error("launch: the running copy never answered; \(urls.count, privacy: .public) URL(s) not handed off")
        }
        exit(0)
    }

    /// `open -a <bundle> <urls>` from a child that waits on this process's exit (`caffeinate -w`, the kernel's
    /// exit event, as `RollbackSwap.relaunchCommand`), so LaunchServices starts a new copy instead of this one.
    private static func reopenAfterExit(bundle: URL, urls: [URL], pastGuard: Bool) {
        let env = pastGuard ? ["--env", "\(SingleInstanceGuard.allowKey)=1"] : []
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "p=$0; shift; /usr/bin/caffeinate -w \"$p\"; exec /usr/bin/open \"$@\"",
                             String(getpid()), "-a", bundle.path] + env + urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
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
    private(set) var pending: [SingleInstanceHandoffEvents.Event] = [.reopen]

    var isDone: Bool { pending.isEmpty }

    mutating func add(_ urls: [URL]) {
        pending.removeAll { $0 == .reopen }
        pending += SingleInstanceHandoffEvents.events(for: urls)
    }

    /// Sends pending events in order; each answered one leaves; the first unanswered one stops the pass.
    mutating func drain(_ send: (SingleInstanceHandoffEvents.Event) -> Bool) {
        while let event = pending.first, send(event) { pending.removeFirst() }
    }

    /// The URLs not answered yet (for a reopen through LaunchServices).
    var unansweredURLs: [URL] {
        pending.flatMap { event -> [URL] in
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
