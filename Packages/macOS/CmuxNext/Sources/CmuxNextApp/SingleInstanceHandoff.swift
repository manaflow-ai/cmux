import AppKit
import os

/// A second copy's hand-off (``SingleInstanceGuard``): a plain `NSApplication` that takes this launch's open
/// events, sends them to the running copy's pid, brings that copy forward, and exits. It never makes
/// `CmuxApplication`, a window, a session, the daemon connection or CEF.
///
/// Events go to the peer's pid, never through LaunchServices by app URL: both copies run from the same bundle, so
/// an open by URL could come back here. Stop condition: it exits once the events are sent, and at most
/// ``deadline`` after launch whatever happens.
@MainActor final class SingleInstanceHandoff: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "launch")
    /// The longest this process lives.
    static let deadline: TimeInterval = 5

    private let peer: SingleInstanceGuard.Peer
    private let activates: Bool
    private var urls: [URL] = []
    private var launched = false

    private init(peer: SingleInstanceGuard.Peer, activates: Bool) {
        self.peer = peer
        self.activates = activates
    }

    /// Runs the hand-off to `peer`; never returns.
    static func run(to peer: SingleInstanceGuard.Peer, activates: Bool) -> Never {
        logger.notice("launch: another copy of this app runs (pid \(peer.pid, privacy: .public)); handing off and exiting before Chromium or the session start")
        // No saved windows of this copy: its restoration store would take over the running copy's.
        UserDefaults.standard.setVolatileDomain(["ApplePersistenceIgnoreState": true], forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        // No Dock icon; an accessory may still be active, so it can hand activation to the peer.
        app.setActivationPolicy(.accessory)
        let handoff = SingleInstanceHandoff(peer: peer, activates: activates)
        app.delegate = handoff
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { exit(0) }
        withExtendedLifetime(handoff) { app.run() }
        exit(0)
    }

    /// This launch's documents and URLs (AppKit routes both `odoc` and `GURL` here); they arrive before
    /// `applicationDidFinishLaunching` for the launch that carried them.
    func application(_ application: NSApplication, open urls: [URL]) {
        self.urls += urls
        if launched { forward() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        // The next turn, after any open event AppKit queued with the launch.
        Task { @MainActor [self] in
            forward()
            exit(0)
        }
    }

    private func forward() {
        let pending = urls
        urls = []
        let events = SingleInstanceHandoffEvents.events(for: pending, reopens: activates)
        for event in events {
            do {
                try SingleInstanceHandoffEvents.descriptor(event, to: peer.pid).sendEvent(options: [.noReply], timeout: 2)
            } catch {
                Self.logger.error("launch: hand-off event to pid \(self.peer.pid, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        Self.logger.notice("launch: handed \(pending.count, privacy: .public) URL(s) to pid \(self.peer.pid, privacy: .public)")
        guard activates, let running = NSRunningApplication(processIdentifier: peer.pid) else { return }
        NSApp.yieldActivation(to: running)
        running.activate()
    }
}

/// The Apple events a hand-off sends: files as one `odoc`, every other URL as its own `GURL`, and a `rapp`
/// (the Dock icon's click: the running copy shows a window if it has none) when nothing else is sent.
nonisolated enum SingleInstanceHandoffEvents {
    enum Event: Equatable {
        case openDocuments([URL])
        case getURL(URL)
        case reopen
    }

    static func events(for urls: [URL], reopens: Bool) -> [Event] {
        let files = urls.filter(\.isFileURL)
        var events: [Event] = files.isEmpty ? [] : [.openDocuments(files)]
        events += urls.filter { !$0.isFileURL }.map(Event.getURL)
        if events.isEmpty, reopens { events = [.reopen] }
        return events
    }

    static func descriptor(_ event: Event, to pid: pid_t) -> NSAppleEventDescriptor {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        func make(_ eventClass: Int, _ eventID: Int) -> NSAppleEventDescriptor {
            NSAppleEventDescriptor(eventClass: AEEventClass(eventClass), eventID: AEEventID(eventID), targetDescriptor: target,
                                   returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        }
        switch event {
        case .openDocuments(let files):
            let descriptor = make(kCoreEventClass, kAEOpenDocuments)
            let list = NSAppleEventDescriptor.list()
            for file in files { list.insert(NSAppleEventDescriptor(fileURL: file), at: 0) }
            descriptor.setParam(list, forKeyword: AEKeyword(keyDirectObject))
            return descriptor
        case .getURL(let url):
            let descriptor = make(kInternetEventClass, kAEGetURL)
            descriptor.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
            return descriptor
        case .reopen:
            return make(kCoreEventClass, kAEReopenApplication)
        }
    }
}
