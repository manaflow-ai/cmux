import AppKit
import CmuxNextWakeups
import Darwin
public import Foundation
import os

/// A second copy's hand-off (``SingleInstanceGuard``): a plain `NSApplication` that takes this launch's open
/// events, starts a helper that waits for this process to exit and then reopens them with
/// `open -b <bundle id> <urls>`, and exits. It never makes `CmuxApplication`, a window, a session, the daemon
/// connection or CEF.
///
/// Delivery is LaunchServices' own once this copy is gone: the running copy gets the URLs and files and comes
/// forward (a bare launch reopens it, as a Dock click does). If that copy quit in the meantime, LaunchServices
/// starts a new one, which takes the claim like any launch. An agent launch (`CMUX_NEXT_NO_ACTIVATE=1`) hands
/// nothing on: any open would bring the person's copy forward.
///
/// Stop conditions: it exits ``settle`` after launch (and after each later open event, so events AppKit delivers
/// after `applicationDidFinishLaunching` still go), and at ``deadline`` whatever happens.
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
        deadline.schedule(after: Self.deadline) { @MainActor in handoff.finish() }
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

    private var finished = false

    /// Starts the helper, then exits. The helper waits on this pid, so LaunchServices never routes back here.
    private func finish() {
        guard !finished else { return }
        finished = true
        let command = Self.reopenCommand(pid: getpid(), bundleIdentifier: Bundle.main.bundleIdentifier ?? "", urls: urls)
        let count = urls.count
        Task.detached(priority: .userInitiated) {
            Self.spawn(command)
            Self.logger.notice("launch: \(count, privacy: .public) URL(s) go to the running copy once this one exits")
            exit(0)
        }
    }

    /// `/bin/sh` that waits on `pid`'s exit (`caffeinate -w`, the kernel's exit event, as
    /// `RollbackSwap.relaunchCommand`), then `open -b <bundle id>` with `urls` (files as paths).
    nonisolated static func reopenCommand(pid: pid_t, bundleIdentifier: String, urls: [URL]) -> [String] {
        ["/bin/sh", "-c", "p=$0; b=$1; shift; /usr/bin/caffeinate -w \"$p\"; exec /usr/bin/open -b \"$b\" \"$@\"",
         String(pid), bundleIdentifier] + urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
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
