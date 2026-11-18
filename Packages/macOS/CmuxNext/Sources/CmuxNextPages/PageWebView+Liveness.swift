public import CmuxNextDesign
public import Foundation

/// The page's half of the agent-chat liveness watchdog (App Health's `liveness` parts, whose rule
/// is cmux-health-core's): a host-to-page ping that needs no input, and the end of a renderer it
/// proved hung. A page beats only while something happens in it and stops at rest, so a chat
/// stuck in a synchronous loop read as resting until now; Chromium's own hang report needs an
/// unanswered input event, so an untouched hung chat never reported either.
extension PageWebView {
    /// Whether the watchdog times this page: an agent chat shown in Chromium.
    public var isTimedForLiveness: Bool { descriptor.isAgentPage && chromiumPage != nil && !isClosed }

    /// The one renderer hosting the page (Chromium's client id); nil when unknown.
    public var rendererClientID: Int32? { chromiumPage?.rendererProcess?.rendererClientID }

    /// That renderer's pid; nil when unknown.
    public var rendererProcessID: Int32? { chromiumPage?.rendererProcess?.rendererProcessID }

    /// Whether the page's DevTools are open (a breakpoint may hold its main thread on purpose).
    public var isBeingDebugged: Bool { chromiumPage?.rendererProcess?.isBeingDebugged ?? false }

    /// The page-to-host messages its bridge took (the page's last message is the latest of them),
    /// with the last one's name and uptime; zero before any.
    public var pageMessages: (count: UInt64, lastName: String?, lastUptime: TimeInterval?) {
        guard let bridge = chromiumSession?.bridge else { return (0, nil, nil) }
        return (bridge.messagesReceived, bridge.lastMessageName, bridge.lastMessageUptime)
    }

    /// One round trip to the page's main thread (`Runtime.evaluate` of `0`, which runs there),
    /// bounded by `timeout` so the call always ends: true when it answered, in any words.
    public func pingMainThread(timeout: Duration) async -> Bool {
        guard let page = chromiumPage, !isClosed else { return false }
        do {
            _ = try await page.devTools("Runtime.evaluate", params: ["expression": "0", "silent": true], timeout: timeout)
            return true
        } catch {
            return false
        }
    }

    /// The watchdog is about to end this page's renderer: its end is a repair, not a crash, so the
    /// page reloads in a new renderer even under a host that shows the crash notice, and once the
    /// new document loads its host shows `notice` (``onRendererRestarted``).
    public func prepareForRendererEnd(notice: String) {
        guard !isClosed else { return }
        rendererRestartPending = true
        pendingRestartNotice = notice
    }

    /// The end did not happen: the page keeps its crash rule and shows no notice.
    public func cancelRendererEnd() {
        rendererRestartPending = false
        pendingRestartNotice = nil
    }

    /// The one-line notice `line` as this page's own toast: its id names the page, so the pages of
    /// one ended renderer that share a window's toasts each show theirs at once instead of
    /// replacing each other; its kind is one for all, so Don't Show Again hides every copy.
    public func rendererRestartedToast(_ line: String) -> CmuxToast {
        CmuxToast(id: "page.rendererRestarted.\(PageRegistry.instance(of: self))", kind: Self.rendererRestartedToastKind, message: line)
    }

    /// The restart toast's Don't Show Again key: the id the agent pane's one toast had before the
    /// toast became each page's own, so a person who hid it keeps it hidden.
    public nonisolated static let rendererRestartedToastKind = "agentPane.rendererRestarted"

    /// The page global the restart line's document script sets (webviews rendererRestartStore.ts
    /// reads it when the pane's module loads, so the line is in the chat's first frame) and the
    /// page's hook it calls when the pane already runs (the script came late).
    nonisolated static let restartFlagGlobal = "__cmuxRendererRestart"
    nonisolated static let restartFlagChanged = "__cmuxRendererRestartChanged"

    /// The document script that tells the page's next document why it loaded: `line`, the
    /// localized restart line, in ``restartFlagGlobal``. It runs once per restart (`restart`, kept
    /// in the tab's sessionStorage), so a later reload of the same tab shows nothing even when the
    /// script could not be taken off.
    nonisolated static func restartFlagScript(line: String, restart: String) -> String {
        let key = ChromiumPageHostWire.jsonString("cmux.rendererRestart." + restart)
        let flag = ChromiumPageHostWire.jsonString(restartFlagGlobal)
        let changed = ChromiumPageHostWire.jsonString(restartFlagChanged)
        return """
        (() => {
          try {
            if (sessionStorage.getItem(\(key))) return;
            sessionStorage.setItem(\(key), "1");
          } catch {}
          globalThis[\(flag)] = { line: \(ChromiumPageHostWire.jsonString(line)) };
          globalThis[\(changed)]?.();
        })();
        """
    }

    /// The watchdog ended this page's renderer and the page reloads: the reload's document gets
    /// the restart line before any of its own scripts run (a new-document script). The pane draws
    /// it as a row in the chat, so every chat of the ended renderer says so, however many share a
    /// window's toasts.
    ///
    /// The reload waits for Chromium to answer the script's registration, at most
    /// ``restartFlagWait``, so a fast navigation cannot reach its first document before the script
    /// is in place. Without an answer in time, or with a failed one, the page reloads anyway (a
    /// chat that stays down is worse than one without its line; the toast still says it
    /// restarted) and the log says why, and when a late answer came. A page with no line to show
    /// (app health's own restart) reloads at once.
    func reloadAfterRestartFlag() {
        guard let line = pendingRestartNotice, let page = chromiumSession?.page else { return reloadPage() }
        let source = Self.restartFlagScript(line: line, restart: UUID().uuidString)
        let id = descriptor.id
        let wait = restartFlagWait
        let asked = ContinuousClock.now
        let logger = self.logger
        let reload = RestartFlagReload()
        // task-owner: the page (`restartFlagScript`); one DevTools call with its own 30 s deadline
        let added = Task { () -> String? in
            let answer = try? await page.devTools("Page.addScriptToEvaluateOnNewDocument",
                                                  params: ["source": source, "runImmediately": true],
                                                  timeout: .seconds(30))
            let identifier = answer.flatMap { ChromiumPageHostWire.object($0)?["identifier"] as? String }
            if reload.timedOut {
                let after = ContinuousClock.now - asked
                logger.error("page \(id, privacy: .public) restart line's script answered \(identifier == nil ? "with a failure" : "ok", privacy: .public) \(String(describing: after), privacy: .public) after it was asked, after the reload started")
            }
            return identifier
        }
        restartFlagScript = added
        // task-owner: the page (`restartFlagReload`); ends within `restartFlagWait`, or with the add's answer
        restartFlagReload = Task { [weak self] in
            guard let self else { return }
            let answered = await self.ended(added, within: wait, owner: "page.restart-flag.wait")
            if !answered {
                reload.timedOut = true
                self.noteRestartFlag("page \(id) restart line's script not answered within \(wait); reloading without waiting (the chat may show only the toast)")
            } else if await added.value == nil {
                self.noteRestartFlag("page \(id) restart line's script failed to register; reloading (the chat shows only the toast)")
            }
            guard !self.isClosed, self.chromiumSession?.page === page else { return }
            self.reloadPage()
        }
    }

    /// Logs why a restarted page reloaded without its restart line in place, and keeps the line for tests.
    private func noteRestartFlag(_ line: String) {
        restartFlagNote = line
        logger.error("\(line, privacy: .public)")
    }

    /// The restarted document loaded: its restart line's script comes off, so no later document
    /// of the page runs it.
    func clearRestartFlag() {
        guard let added = restartFlagScript, let page = chromiumSession?.page else { return }
        restartFlagScript = nil
        // task-owner: the page (`restartFlagRemoval`); one bounded DevTools call after the add's answer
        restartFlagRemoval = Task {
            guard let identifier = await added.value else { return }
            _ = try? await page.devTools("Page.removeScriptToEvaluateOnNewDocument", params: ["identifier": identifier])
        }
    }

    /// Ends the one renderer `pages` share, by force (``PageRendererProcess/endRenderer()``):
    /// every page in that renderer is marked first to reload as a repair and to show `notice` once
    /// it loads again, `pages` and every other open page the renderer hosts (a chat still booting
    /// that no watchdog part has timed yet ends with it too), then the renderer ends; when nothing
    /// ended, the marks are taken back. Returns the pid ended (0: ended, pid unknown), or nil.
    public static func endHungRenderer(of pages: [PageWebView], notice: String) -> Int32? {
        guard let renderer = pages.lazy.filter({ !$0.isClosed }).compactMap({ $0.chromiumPage?.rendererProcess }).first else { return nil }
        let marked = pages + pagesHosted(by: renderer).filter { page in !pages.contains { $0 === page } }
        for page in marked { page.prepareForRendererEnd(notice: notice) }
        guard let ended = renderer.endRenderer() else {
            for page in marked { page.cancelRendererEnd() }
            return nil
        }
        return ended
    }

    /// The open pages `renderer` hosts: the same process object, or the same Chromium renderer client id.
    static func pagesHosted(by renderer: any PageRendererProcess) -> [PageWebView] {
        let client = renderer.rendererClientID
        return PageRegistry.pages().filter { page in
            guard !page.isClosed, let process = page.chromiumPage?.rendererProcess else { return false }
            return process === renderer || (client != nil && process.rendererClientID == client)
        }
    }

    /// This page in the watchdog's log line: who it is (``logIdentity``, else its page id), its
    /// pane, whether it shows, and its last page-to-host message (seq, name, age at `now`, in
    /// `systemUptime` seconds). Every page of a hung renderer is named: they share one main
    /// thread, so the host cannot tell which page's script holds it.
    public func livenessLogEntry(visible: Bool, now: TimeInterval) -> String {
        let messages = pageMessages
        let last = messages.lastUptime.map { String(format: "%.0f s ago", now - $0) } ?? "never"
        let who = logIdentity?() ?? "page \(descriptor.id)"
        return "[\(who) pane=\(healthPartID) \(visible ? "visible" : "hidden") lastMessage=#\(messages.count) \(messages.lastName ?? "none") \(last)]"
    }
}

/// Whether a restarted page's reload stopped waiting for its restart line's script (the wait ran
/// out), so a late answer is logged as late.
@MainActor
final class RestartFlagReload {
    var timedOut = false
}
