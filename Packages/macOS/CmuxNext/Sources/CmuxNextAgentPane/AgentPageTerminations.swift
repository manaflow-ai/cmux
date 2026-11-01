import CmuxNextCompat
import CmuxNextPages
import Foundation
import os

nonisolated private let terminationLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.webview")

/// The agent pages that ended in one web content process termination (cmux issue 28710).
///
/// Agent pages share web content processes (``WebProcessGroups``, 8 pages per process), so one
/// process end (a crash after the GPU process went, a memory limit) shows the crash notice in
/// every chat of its group at once. WebKit tells each page separately; this groups them again:
/// pages that report the same WebContent pid, or, with no pid known, that report in the same
/// main-loop turn (WebKit tells every page of an ended process in one turn), ended together.
///
/// Each page's end is logged at error level with WebKit's reason, the pid, the page and how many
/// pages ended with it so far; when the turn ends, one line and one crash marker
/// (`~/Library/Logs/cmux-next/<bundle>-webkit-agent-page-<time>-<n>.json`) give the whole group. The
/// Reload of any of those chats is the person's request for all of them: it reloads every page of
/// the group that still shows the notice. A page first loads again by itself
/// (``AgentPageCrashRetry``); only one that keeps ending shows the notice.
///
/// The agent panes' ``WebProcessGroups`` (which put the pages into shared processes) hold the
/// one every pane uses; a test gives its panes its own.
@MainActor
public final class AgentPageTerminations {
    public init() {}

    /// One termination: the pages it ended, in the order they reported.
    final class Event {
        let reason: PageTermination.Reason
        private(set) var pid: Int32
        let date: Date
        let serial: Int
        private(set) var pages: [Page] = []

        struct Page {
            weak var view: AgentPaneView?
            let page: String
            let session: String?
            let engine: String
        }

        init(reason: PageTermination.Reason, pid: Int32, date: Date, serial: Int) {
            (self.reason, self.pid, self.date, self.serial) = (reason, pid, date, serial)
        }

        func add(_ page: Page, pid: Int32) {
            if self.pid == 0 { self.pid = pid }
            pages.append(page)
        }

        func remove(_ view: AgentPaneView) {
            pages.removeAll { $0.view === view || $0.view == nil }
        }

        func contains(_ view: AgentPaneView) -> Bool { pages.contains { $0.view === view } }

        /// The pages that still show the crash notice.
        var waiting: [AgentPaneView] { pages.compactMap(\.view).filter(\.showsCrashNotice) }
    }

    /// How long after an event's first page a page with the same pid still joins it (a later
    /// process can get a recycled pid).
    var joinWindow: TimeInterval = 10
    var now: () -> Date = Date.init
    /// Runs `body` after the current main-loop turn: the end of a burst of page ends.
    var afterTurn: (@escaping @MainActor () -> Void) -> Void = { body in Task { @MainActor in body() } }
    /// Takes the crash marker of an ended group (its JSON, start date and serial); the default
    /// writes it under `~/Library/Logs/cmux-next` off the main thread, and nothing in a test process.
    var writeMarker: (_ json: Data, _ date: Date, _ serial: Int) -> Void = AgentPageTerminations.writeToLogs

    /// Events whose pages wait for a Reload.
    private(set) var events: [Event] = []
    /// Events that pages joined in this main-loop turn (reported when it ends).
    private var turn: [Event] = []
    private var serial = 0

    /// `view`'s page ended with `termination` (`retries`: it loads again by itself, else it shows
    /// the crash notice); returns the event it joined.
    @discardableResult
    func ended(_ view: AgentPaneView, termination: PageTermination, retries: Bool = false) -> Event {
        for event in events { event.remove(view) }
        let event = join(termination) ?? start(termination)
        if !events.contains(where: { $0 === event }) { events.append(event) }
        event.add(Event.Page(view: view, page: Self.pageName(view), session: view.model.sessionId, engine: view.engineName),
                  pid: termination.pid)
        // An event none of whose pages still shows the notice is done (the pages closed or reloaded).
        events.removeAll { $0 !== event && $0.waiting.isEmpty }
        let page = event.pages.last
        terminationLogger.error("agent page web content ended reason=\(termination.reason.rawValue, privacy: .public) pid=\(termination.pid) page=\(page?.page ?? "-", privacy: .public) session=\(page?.session ?? "none", privacy: .public) engine=\(page?.engine ?? "-", privacy: .public) ended_with_it=\(event.pages.count) event=\(event.serial); \(retries ? "loads again by itself" : "kept ending: the crash notice offers Reload", privacy: .public)")
        if !turn.contains(where: { $0 === event }) {
            if turn.isEmpty { afterTurn { [weak self] in self?.endTurn() } }
            turn.append(event)
        }
        return event
    }

    /// The person pressed Reload in `view`'s notice: reloads every page of its event that still
    /// shows the notice (`view` first), and none of any other event.
    func reload(from view: AgentPaneView) {
        guard let index = events.firstIndex(where: { $0.contains(view) }) else {
            view.reloadAfterCrash()
            return
        }
        let event = events.remove(at: index)
        let others = event.waiting.filter { $0 !== view }
        if others.isEmpty == false {
            terminationLogger.error("agent page Reload reloads \(others.count + 1) pages that ended together event=\(event.serial) pid=\(event.pid)")
        }
        view.reloadAfterCrash()
        for other in others { other.reloadAfterCrash() }
    }

    /// `view` closed: a sibling's Reload must not reload it.
    func forget(_ view: AgentPaneView) {
        for event in events { event.remove(view) }
        events.removeAll { $0.waiting.isEmpty }
    }

    /// `view` loaded its page again after it ended (no Reload): logged, and it leaves its event so
    /// a sibling's Reload does not reload a live chat.
    func loadedAgain(_ view: AgentPaneView, session: String?) {
        let serial = event(of: view)?.serial
        forget(view)
        terminationLogger.error("agent page loaded again after it ended; crash notice removed session=\(session ?? "none", privacy: .public) event=\(serial.map(String.init) ?? "-", privacy: .public)")
    }

    /// The event `view` waits on, if any (tests, `debug.agent_pane`).
    func event(of view: AgentPaneView) -> Event? { events.first { $0.contains(view) } }

    /// Ends the current turn's burst now: its summary lines and crash markers (tests call it in
    /// place of the next main-loop turn).
    func endTurn() {
        let ended = turn
        turn = []
        for event in ended where !event.pages.isEmpty {
            let sessions = event.pages.map { $0.session ?? "none" }.joined(separator: ",")
            terminationLogger.error("agent pages ended together reason=\(event.reason.rawValue, privacy: .public) pid=\(event.pid) pages=\(event.pages.count) sessions=\(sessions, privacy: .public) event=\(event.serial); one Reload reloads those that show the notice")
            writeMarker(Self.marker(event), event.date, event.serial)
        }
    }

    private func join(_ termination: PageTermination) -> Event? {
        // Same turn, same reason: one pid, or a page whose pid is not known.
        if let event = turn.last(where: { $0.reason == termination.reason && ($0.pid == termination.pid || $0.pid == 0 || termination.pid == 0) }) {
            return event
        }
        // A sibling that reports in a later turn: the same pid, soon after.
        guard termination.pid != 0 else { return nil }
        let date = now()
        return events.last { $0.pid == termination.pid && date.timeIntervalSince($0.date) <= joinWindow }
    }

    private func start(_ termination: PageTermination) -> Event {
        serial += 1
        let event = Event(reason: termination.reason, pid: termination.pid, date: now(), serial: serial)
        events.append(event)
        return event
    }

    /// The page's name in a log line or marker: its session, or `new-tab`.
    private static func pageName(_ view: AgentPaneView) -> String {
        view.model.sessionId.map { "chat:\($0)" } ?? "new-tab"
    }

    /// The crash marker of `event`: no typed text, URL or title, as the Chromium renderer marker.
    static func marker(_ event: Event, bundleID: String? = Bundle.main.bundleIdentifier) -> Data {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = [info["CFBundleShortVersionString"] as? String, info["CFBundleVersion"] as? String]
            .compactMap { $0 }.joined(separator: " ")
        var object: [String: Any] = [
            "kind": "webkit",
            "process_type": "web-content",
            "host": "agent-page",
            "date": event.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)),
            "reason": event.reason.rawValue,
            "pages_ended": event.pages.count,
            "pages": event.pages.map { page -> [String: String] in
                var entry = ["page": page.page, "engine": page.engine]
                if let session = page.session { entry["session"] = session }
                return entry
            },
            "bundle_id": bundleID ?? "unknown",
            "version": version.isEmpty ? "unknown" : version,
        ]
        if event.pid != 0 { object["pid"] = Int(event.pid) }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    /// Writes a marker as `<bundle>-webkit-agent-page-<time>-<serial>.json` in
    /// `~/Library/Logs/cmux-next` (beside the Chromium renderer markers), off the main thread;
    /// nothing in a test process. The serial keeps two processes that ended in the same
    /// millisecond apart; a sibling that joins its event later rewrites that event's file.
    nonisolated static func writeToLogs(_ json: Data, date: Date, serial: Int) {
        let process = ProcessInfo.processInfo
        guard !AcpmuxEnvironment.isTestProcess(name: process.processName, environment: process.environment) else { return }
        let bundle = String((Bundle.main.bundleIdentifier ?? "unknown").map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let stamp = String(format: "%04d%02d%02d-%02d%02d%02d-%03d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                           parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, (parts.nanosecond ?? 0) / 1_000_000)
        Task.detached(priority: .utility) {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/cmux-next", directoryHint: .isDirectory)
            do {
                try FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true)
                try json.blockingWrite(to: directory.appending(path: "\(bundle)-webkit-agent-page-\(stamp)-\(serial).json"), options: .atomic)
            } catch {
                terminationLogger.error("agent page crash marker write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
