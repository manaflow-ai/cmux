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
    static let deadline: Duration = .seconds(4)
    static let hardDeadline: TimeInterval = 6

    private let lock: URL
    /// URLs not yet answered by the owner.
    private var pending: [URL] = []
    /// A bare launch's `rapp` still to send.
    private var reopenPending = true
    private var launched = false
    private var finishing: Task<Void, Never>?

    private init(lock: URL) {
        self.lock = lock
    }

    /// Runs the hand-off to the owner of `lock`; never returns.
    static func run(lock: URL, activates: Bool) -> Never {
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
        let handoff = SingleInstanceHandoff(lock: lock)
        app.delegate = handoff
        withExtendedLifetime(handoff) { app.run() }
        exit(0)
    }

    /// This launch's documents and URLs (AppKit routes both `odoc` and `GURL` here).
    func application(_ application: NSApplication, open urls: [URL]) {
        pending += urls
        reopenPending = false
        if launched { attempt() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.deadline)
            self?.giveUp()
        }
        attempt()
    }

    /// Sends what is pending; then exits after the settle time, or tries again shortly.
    private func attempt() {
        finishing?.cancel()
        let owner = SingleInstanceGuard.owner(at: lock)
        if let owner {
            if !pending.isEmpty {
                let urls = pending
                if send(SingleInstanceHandoffEvents.events(for: urls), to: owner) {
                    pending.removeAll { urls.contains($0) }
                    Self.logger.notice("launch: handed \(urls.count, privacy: .public) URL(s) to pid \(owner, privacy: .public)")
                }
            } else if reopenPending, send([.reopen], to: owner) {
                reopenPending = false
            }
        }
        let done = pending.isEmpty && !reopenPending
        finishing = Task { [weak self] in
            try? await Task.sleep(for: done ? Self.settle : Self.retry)
            guard !Task.isCancelled, let self else { return }
            if done { self.finish(owner: owner) } else { self.attempt() }
        }
    }

    /// Sends `events` to `owner`, each waiting for its reply; false when one was not answered.
    private func send(_ events: [SingleInstanceHandoffEvents.Event], to owner: pid_t) -> Bool {
        for event in events {
            do {
                _ = try SingleInstanceHandoffEvents.descriptor(event, to: owner).sendEvent(options: [.waitForReply], timeout: 1)
            } catch {
                Self.logger.error("launch: hand-off event to pid \(owner, privacy: .public) not answered: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        return true
    }

    private func finish(owner: pid_t?) {
        if let owner, let running = NSRunningApplication(processIdentifier: owner) {
            NSApp.yieldActivation(to: running)
            running.activate()
        }
        exit(0)
    }

    /// The deadline with events still pending. The owner ended (the claim is free): the launch reopens through
    /// LaunchServices. The claim is held but its recorded owner is gone (a leaked descriptor, not a copy of the
    /// app): the launch reopens past the guard (`CMUX_NEXT_ALLOW_SECOND_INSTANCE=1`), so cmux never becomes
    /// unlaunchable. The owner is alive but never answered: the launch is dropped, logged.
    private func giveUp() {
        guard !pending.isEmpty || reopenPending else { return }
        let owner = SingleInstanceGuard.owner(at: lock)
        if SingleInstanceGuard.isFree(at: lock) {
            Self.logger.notice("launch: the running copy exited during the hand-off; reopening this launch")
            Self.reopenAfterExit(bundle: Bundle.main.bundleURL, urls: pending, pastGuard: false)
        } else if let owner, kill(owner, 0) != 0, errno == ESRCH {
            Self.logger.error("launch: the claim is held but its owner pid \(owner, privacy: .public) is gone; reopening past the guard")
            Self.reopenAfterExit(bundle: Bundle.main.bundleURL, urls: pending, pastGuard: true)
        } else {
            Self.logger.error("launch: the running copy never answered; \(self.pending.count, privacy: .public) URL(s) not handed off")
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
