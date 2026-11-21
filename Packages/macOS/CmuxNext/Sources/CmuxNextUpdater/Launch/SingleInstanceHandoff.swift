import AppKit
import CmuxNextCompat
import CmuxNextWakeups
import Darwin
public import Foundation
import os

/// A second copy's hand-off (``SingleInstanceGuard``): a plain `NSApplication` that takes this launch's open
/// events, starts a helper that waits for this process to exit and then reopens them with
/// `open -a <the running copy's bundle> <urls>`, and exits. It never makes `CmuxApplication`, a window, a session,
/// the daemon connection or CEF.
///
/// The target is the copy that holds the claim, read from its owner record (`SingleInstanceGuard.runningCopy`),
/// never whatever the bundle id resolves to: on a Mac with an older copy registered under the same id, `open -b`
/// started that older copy (no guard, so its Chromium failed and its tabs fell back to WebKit). When the running
/// copy cannot be resolved by ``deadline``, or its bundle is gone from disk, the URLs go in the second-copy note
/// (``SecondCopyNote``), which the running copy opens. Either way the running copy hears which copy was opened and
/// says so (``AppCopyGuide``). Delivery is
/// LaunchServices' own once this copy is gone: the running copy gets the URLs and files and comes forward (a bare
/// launch reopens it, as a Dock click does). If that copy quit in the meantime, LaunchServices starts that same
/// bundle again, which takes the claim like any launch. An agent launch (`CMUX_NEXT_NO_ACTIVATE=1`) hands nothing
/// on: any open would bring the person's copy forward.
///
/// Stop conditions: it exits ``settle`` after launch, the last open event and the last helper (so events AppKit
/// delivers late still go), and at ``deadline`` once the URLs in hand have a helper, whatever arrives after. An
/// unresolved owner retries on the same ``settle`` timer, so the ``deadline`` bounds it too.
@MainActor final class SingleInstanceHandoff: NSObject, NSApplicationDelegate {
    nonisolated private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "launch")
    nonisolated static let settle: Duration = .milliseconds(300)
    nonisolated static let deadline: Duration = .seconds(3)

    private var urls: [URL] = []
    /// Exits ``settle`` after the last open event.
    private let quiet = DemandTimer(owner: "SingleInstanceHandoff.quiet")

    /// Runs the hand-off; never returns.
    static func run(activates: Bool) -> Never {
        logger.notice("launch: another copy of this app runs; handing off and exiting before Chromium or the session start")
        guard activates else {
            logger.notice("launch: an agent launch of a second copy hands nothing on (the running copy would come forward); exiting")
            exit(0)
        }
        // `run` never returns, so this timer lives until the exit.
        let deadline = DemandTimer(owner: "SingleInstanceHandoff.deadline")
        let handoff = SingleInstanceHandoff()
        deadline.schedule(after: Self.deadline) { @MainActor in handoff.finish(deadline: true) }
        // No saved windows of this copy: its restoration store would take over the running copy's.
        UserDefaults.standard.setVolatileDomain(["ApplePersistenceIgnoreState": true], forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        // No Dock icon.
        app.setActivationPolicy(.accessory)
        app.delegate = handoff
        // A URL launch arrives as `GURL`; take it here (as the app's own delegate does), before AppKit starts.
        NSAppleEventManager.shared().setEventHandler(handoff, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        withExtendedLifetime((handoff, deadline)) { app.run() }
        exit(0)
    }

    /// This launch's documents and URLs (AppKit routes both `odoc` and `GURL` here).
    func application(_ application: NSApplication, open urls: [URL]) {
        self.urls += urls
        scheduleFinish()
    }

    @objc(handleURLEvent:reply:) private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else { return }
        urls.append(url)
        scheduleFinish()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        scheduleFinish()
    }

    private func scheduleFinish() {
        quiet.schedule(after: Self.settle) { @MainActor [weak self] in self?.finish() }
    }

    /// How many of ``urls`` a helper already carries; nil before the first helper.
    private var handed: Int?
    /// A helper is starting; its end settles again (``helperStarted()``).
    private var starting = false
    /// The deadline passed: exit once the URLs in hand have a helper, whatever arrives after.
    private var closing = false

    /// Starts a helper for the URLs no helper carries yet (a bare launch: one with none). The process exits
    /// only from here, ``settle`` after the last helper started and the last open event came in, with the run
    /// loop turning all along: an event AppKit had queued meanwhile reaches the delegate, re-arms the settle and
    /// gets its own helper. Each helper waits on this pid, so LaunchServices never routes back here.
    private func finish(deadline: Bool = false) {
        closing = closing || deadline
        guard !starting else { return }
        let batch = Array(urls[(handed ?? 0)...])
        // The first helper always starts (a bare launch reopens the running copy); a later one only for new URLs.
        guard handed == nil || !batch.isEmpty else { exit(0) }
        let handedBefore = handed
        handed = urls.count
        starting = true
        let pid = getpid(), first = handedBefore == nil, closing = self.closing
        let bundleIdentifier = Bundle.main.bundleIdentifier, openedPath = Bundle.main.bundlePath
        let ownerURL = bundleIdentifier
            .flatMap { SingleInstanceGuard.lockURL(bundleIdentifier: $0) }
            .map(SingleInstanceGuard.ownerURL(lockURL:))
        // task-owner: the hand-off process; `helperEnded` settles, retries or exits after it.
        Task.detached(priority: .userInitiated) { [weak self] in
            let route = Self.route(owner: ownerURL.flatMap { SingleInstanceGuard.runningCopy(at: $0, selfPID: pid) },
                                   bundleExists: { FileManager.checked.fileExists(atPath: $0) }, closing: closing)
            switch route {
            case .retry:
                await self?.helperEnded(delivered: false, handedBefore: handedBefore)
                return
            case .launchServices(let owner):
                Self.spawn(Self.reopenCommand(pid: pid, appPath: owner.bundlePath, urls: batch))
                Self.logger.notice(
                    "launch: \(batch.count, privacy: .public) URL(s) go to pid \(owner.pid, privacy: .public) at \(owner.bundlePath, privacy: .public) after exit")
                // The running copy says which copy was opened (``AppCopyGuide``); the URLs went to LaunchServices.
                if first, let bundleIdentifier { SecondCopyNote(openedPath: openedPath).post(bundleIdentifier: bundleIdentifier) }
            case .note:
                // LaunchServices cannot reach the running copy (its bundle is gone, or its owner record never
                // resolved): the note carries the URLs, and the running copy opens them.
                Self.logger.notice("launch: \(batch.count, privacy: .public) URL(s) go to the running copy in the second-copy note")
                if let bundleIdentifier {
                    for note in SecondCopyNote.notes(openedPath: openedPath, urls: batch) { note.post(bundleIdentifier: bundleIdentifier) }
                }
            }
            await self?.helperEnded(delivered: true, handedBefore: handedBefore)
        }
    }

    /// How a batch reaches the running copy.
    nonisolated enum Route: Equatable, Sendable {
        /// The owner record does not resolve yet: try again at the next settle.
        case retry
        /// `open -a` the owner's bundle once this process exits.
        case launchServices(SingleInstanceGuard.Owner)
        /// The second-copy note carries the URLs (``SecondCopyNote``): the owner's bundle is gone from disk (moved or
        /// deleted while it ran, so `open -a` would find nothing), or the record never resolved by the deadline.
        case note
    }

    nonisolated static func route(owner: SingleInstanceGuard.Owner?, bundleExists: (String) -> Bool, closing: Bool) -> Route {
        guard let owner else { return closing ? .note : .retry }
        return bundleExists(owner.bundlePath) ? .launchServices(owner) : .note
    }

    /// After a helper attempt. One whose running copy is not resolvable yet (its owner may be between taking
    /// the claim and writing its record) is retried at the next ``settle``, until ``deadline``; after the
    /// deadline its URLs go in the second-copy note (``Route/note``), never dropped. Never `open -b`: the bundle
    /// id may resolve to an older copy with no guard (nightly proof, 2026-10-27).
    private func helperEnded(delivered: Bool, handedBefore: Int?) {
        starting = false
        if !delivered { handed = handedBefore }  // the same URLs go again at the next settle
        if closing { finish(deadline: true) } else { scheduleFinish() }
    }

    /// `/bin/sh` that waits on `pid`'s exit (`caffeinate -w`, the kernel's exit event, as
    /// `RollbackSwap.relaunchCommand`), then `open -a <appPath>` with `urls` (files as paths): that exact bundle,
    /// never a lookup by bundle id.
    nonisolated static func reopenCommand(pid: pid_t, appPath: String, urls: [URL]) -> [String] {
        ["/bin/sh", "-c", "p=$0; a=$1; shift; /usr/bin/caffeinate -w \"$p\"; exec /usr/bin/open -a \"$a\" \"$@\"",
         String(pid), appPath] + urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
    }

    private nonisolated static func spawn(_ command: [String]) {
        let process = Process()
        process.executableURL = URL(filePath: command[0])
        process.arguments = Array(command.dropFirst())
        do { try process.run() } catch {
            logger.error("launch: the hand-off helper did not start: \(String(describing: error), privacy: .public)")
        }
    }
}

public extension SingleInstanceGuard {
    /// Hands this launch to the running copy and exits (``SingleInstanceHandoff``); never returns.
    @MainActor static func handOff(activates: Bool) -> Never {
        SingleInstanceHandoff.run(activates: activates)
    }
}
