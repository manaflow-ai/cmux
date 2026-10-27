import AppKit
import os

/// A second copy's hand-off (``SingleInstanceGuard``): a plain `NSApplication` that takes this launch's open
/// events, sends them to the owner's pid, brings the owner forward, and exits. It never makes `CmuxApplication`,
/// a window, a session, the daemon connection or CEF.
///
/// Events go to the owner's pid, never through LaunchServices by app URL: both copies run from the same bundle, so
/// an open by URL could come back here. If the owner is gone when they are sent (it quit in between), this launch
/// is reopened through LaunchServices with its URLs once this process has exited. An agent launch
/// (`CMUX_NEXT_NO_ACTIVATE=1`) forwards nothing: any open would bring the owner forward.
///
/// Stop conditions: it exits ``settle`` after the last event it took (so open events AppKit delivers after
/// `applicationDidFinishLaunching` still go), and at most ``deadline`` after launch, from a timer off the main
/// thread, so a blocked send cannot hold it.
@MainActor final class SingleInstanceHandoff: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "launch")
    /// The longest this process lives.
    static let deadline: TimeInterval = 5
    /// The quiet time after launch (and after each later open event) before it exits.
    static let settle: TimeInterval = 0.3

    private let owner: pid_t
    private var pending: [URL] = []
    private var sentAny = false
    private var launched = false
    private var finishing: DispatchWorkItem?

    private init(owner: pid_t) {
        self.owner = owner
    }

    /// Runs the hand-off to `owner`; never returns.
    static func run(to owner: pid_t, activates: Bool) -> Never {
        logger.notice("launch: another copy of this app runs (pid \(owner, privacy: .public)); handing off and exiting before Chromium or the session start")
        guard activates else {
            logger.notice("launch: an agent launch of a second copy forwards nothing (the running copy would come forward); exiting")
            exit(0)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { exit(0) }
        // No saved windows of this copy: its restoration store would take over the running copy's.
        UserDefaults.standard.setVolatileDomain(["ApplePersistenceIgnoreState": true], forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        // No Dock icon; an accessory may still be active, so it can hand activation to the owner.
        app.setActivationPolicy(.accessory)
        let handoff = SingleInstanceHandoff(owner: owner)
        app.delegate = handoff
        withExtendedLifetime(handoff) { app.run() }
        exit(0)
    }

    /// This launch's documents and URLs (AppKit routes both `odoc` and `GURL` here).
    func application(_ application: NSApplication, open urls: [URL]) {
        pending += urls
        guard launched else { return }
        forward()
        scheduleFinish()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        forward()
        scheduleFinish()
    }

    private func scheduleFinish() {
        finishing?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.finish() } }
        finishing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    /// Nothing more arrived: a bare launch brings the owner forward (`rapp`), then this process exits.
    private func finish() {
        if !sentAny { send([.reopen], urls: []) }
        if let running = NSRunningApplication(processIdentifier: owner) {
            NSApp.yieldActivation(to: running)
            running.activate()
        }
        exit(0)
    }

    private func forward() {
        let urls = pending
        pending = []
        guard !urls.isEmpty else { return }
        send(SingleInstanceHandoffEvents.events(for: urls), urls: urls)
        sentAny = true
    }

    private func send(_ events: [SingleInstanceHandoffEvents.Event], urls: [URL]) {
        var failed = false
        for event in events {
            do {
                try SingleInstanceHandoffEvents.descriptor(event, to: owner).sendEvent(options: [.noReply], timeout: 1)
            } catch {
                failed = true
                Self.logger.error("launch: hand-off event to pid \(self.owner, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        Self.logger.notice("launch: handed \(urls.count, privacy: .public) URL(s) to pid \(self.owner, privacy: .public)")
        guard failed, kill(owner, 0) != 0, errno == ESRCH else { return }
        // The owner quit in between: this launch reopens through LaunchServices once this process has exited.
        Self.logger.notice("launch: pid \(self.owner, privacy: .public) exited during the hand-off; reopening this launch")
        Self.reopenAfterExit(bundle: Bundle.main.bundleURL, urls: urls)
        exit(0)
    }

    /// `open -a <bundle> <urls>` from a child that waits (at most 5 s) for this process to exit first, so
    /// LaunchServices starts a new copy instead of routing back here.
    private static func reopenAfterExit(bundle: URL, urls: [URL]) {
        let script = "p=$0; a=$1; shift; i=0; while /bin/kill -0 \"$p\" 2>/dev/null && [ $i -lt 100 ]; do /bin/sleep 0.05; i=$((i+1)); done; exec /usr/bin/open -a \"$a\" \"$@\""
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, String(getpid()), bundle.path] + urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
        do { try process.run() } catch {
            logger.error("launch: reopen failed: \(String(describing: error), privacy: .public)")
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
