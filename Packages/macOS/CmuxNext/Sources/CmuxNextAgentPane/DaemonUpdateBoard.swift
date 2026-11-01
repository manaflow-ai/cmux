import AppKit
import CmuxNextDesign
import Foundation
public import Observation

/// The latest update state of each ``DaemonUpdateTarget``, as ``DaemonUpdatePolicy`` reports it:
/// an ssh machine's sidebar tooltip shows its line (``detail(sshHost:)``), another surface looks a
/// target up by id (``detail(id:)``), and Settings > Updates lists the machines that cannot update,
/// are offline or failed to, in one row (``otherMachines``). Failed or rolled-back updates share one
/// toast that stays until closed (``noticeToast(_:)``): the machines' names in plain words, each
/// reason in its tooltip and behind Details, which shows the reasons in the toast itself, never
/// Settings. Closed, it stays closed for that build, also across launches. A machine that cannot
/// update in place or is offline never has a toast. The app has one (``DaemonUpdates/board``, made
/// once by `AppServices`): the policy writes it, the sidebar of every window and Settings read it.
@MainActor @Observable
public final class DaemonUpdateBoard {
    /// The latest event per target id.
    public private(set) var targets: [String: DaemonUpdateEvent] = [:]
    /// Machines whose Update the person clicked (``update(_:retry:)``), until their update ends.
    private var clicked: Set<String> = []

    /// The one toast of the failures and what closing it does. Its Details is the toast's own: it
    /// shows the reasons in place.
    struct Notice {
        var toast: CmuxToast
        /// The person closed it: it stays closed for its build.
        var closed: @MainActor () -> Void
    }

    /// Shows the notice's toast in the front window, unless replaced (tests); returns its handle. A
    /// process with no application (a test of the policy with a real board) shows nothing.
    @ObservationIgnored var showNotice: @MainActor (Notice) -> CmuxToastHandle? = { notice in
        guard let app = NSApp as NSApplication?,
              let window = DaemonUpdateBoard.noticeWindow(key: app.keyWindow, main: app.mainWindow, ordered: app.orderedWindows)
        else { return nil }
        let handle = CmuxToastCenter.shared.show(notice.toast, in: window)
        handle.onDismiss = { [weak window] reason in
            guard reason == .closed else {
                if DaemonUpdateBoard.closedByPerson(reason, windowShown: true) { notice.closed() }
                return
            }
            // `closed` is also the toast's window closing (the toast center ends its toasts so):
            // only a close button in a window still shown is the person's. Read once the close
            // has settled, when a closing window is no longer visible.
            let closing = window
            // task-owner: one read after this turn; ends at once
            Task { @MainActor in
                if DaemonUpdateBoard.closedByPerson(reason, windowShown: closing?.isVisible == true) { notice.closed() }
            }
        }
        return handle
    }

    /// Whether a toast that ended for `reason` was closed by the person: its close button in a
    /// window still shown, or an action that ends it (Details does not). Its window closing, a newer
    /// notice in its place, or a timeout is not.
    nonisolated static func closedByPerson(_ reason: CmuxToastDismissReason, windowShown: Bool) -> Bool {
        switch reason {
        case .action: true
        case .closed: windowShown
        case .replaced, .timeout: false
        }
    }

    /// Where the build whose notice the person closed is kept, so it stays closed after a relaunch;
    /// nil keeps it in memory only. Only the app's (``DaemonUpdates/board``) keeps the app's file: a
    /// board a test makes never reads or writes it.
    let closedNoticeFile: URL?
    @ObservationIgnored private var closedBuild: String?
    /// The read of ``closedNoticeFile`` (off the main actor); until it ends, failures are kept but
    /// shown only once it says whether their build was closed.
    @ObservationIgnored private var closedRead: Task<Void, Never>?
    /// The last write of ``closedNoticeFile``; each waits for the one before, so the newest close wins.
    @ObservationIgnored private var closedWrite: Task<Void, Never>?
    /// The failures the notice shows: of one build (the newest that failed), by target id.
    @ObservationIgnored private var failures: [String: DaemonUpdateEvent] = [:]
    @ObservationIgnored private var failureBuild: String?
    /// The notice showing now, so a new one replaces it wherever it is: one at a time.
    @ObservationIgnored private var shown: CmuxToastHandle?

    public init() {
        closedNoticeFile = nil
    }

    init(closedNoticeFile: URL?) {
        self.closedNoticeFile = closedNoticeFile
        guard let closedNoticeFile else { return }
        // task-owner: the board; one read of a few bytes, then it ends
        closedRead = Task { [weak self] in
            let build = await Self.readClosed(closedNoticeFile)
            self?.didReadClosed(build)
        }
    }

    /// Returns once ``closedNoticeFile`` is read and every close so far is written (tests).
    func settled() async {
        await closedRead?.value
        await closedWrite?.value
    }

    @concurrent nonisolated private static func readClosed(_ file: URL) async -> String? {
        try? String(contentsOf: file, encoding: .utf8)
    }

    @concurrent nonisolated private static func writeClosed(_ build: String, to file: URL) async {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? Data(build.utf8).write(to: file, options: .atomic)
    }

    private func didReadClosed(_ build: String?) {
        closedRead = nil
        // A close in this run since wins over the file.
        if closedBuild == nil { closedBuild = build }
        if let failureBuild, failureBuild == closedBuild { failures = [:] }
        showFailures()
    }

    /// What ``noticeWindow(key:main:ordered:rules:)`` asks of a window; ``live`` reads AppKit and
    /// the window kit, tests replace it.
    struct NoticeWindowRules {
        /// The window a window acts for: a sheet, palette or panel stands for the window it is over.
        var root: (NSWindow) -> NSWindow = { $0.windowKindRoot }
        /// A workspace window (``WindowKind/main``): never settings, debug settings, a page's window.
        var isWorkspace: (NSWindow) -> Bool = { $0.windowKind == .main }
        /// On screen where the person is: shown, not minimized, on the active Space.
        var inView: (NSWindow) -> Bool = { $0.isVisible && !$0.isMiniaturized && $0.isOnActiveSpace }
        /// Shown at all: on another Space, or minimized.
        var shown: (NSWindow) -> Bool = { $0.isVisible || $0.isMiniaturized }

        static let live = NoticeWindowRules()
    }

    /// The window a notice goes to: a workspace window, the one the key window, else the main
    /// window, else the frontmost window acts for. One in view on the active Space comes before one
    /// on another Space or minimized, which still gets the notice, since it stays until closed.
    /// An update fails in the background, often while the app is not active, and AppKit then has no
    /// key or main window: the frontmost workspace window takes it.
    static func noticeWindow(key: NSWindow?, main: NSWindow?, ordered: [NSWindow], rules: NoticeWindowRules = .live) -> NSWindow? {
        var seen = Set<ObjectIdentifier>()
        let workspaces = ([key, main] + ordered.map(Optional.some)).compactMap { $0.map(rules.root) }
            .filter { rules.isWorkspace($0) && seen.insert(ObjectIdentifier($0)).inserted }
        return workspaces.first(where: rules.inView) ?? workspaces.first(where: rules.shown)
    }

    public func apply(_ event: DaemonUpdateEvent) {
        if event.state != .updating, event.state != .retrying { clicked.remove(event.id) }
        guard event.state != .cleared else {
            targets[event.id] = nil
            failures[event.id] = nil
            return
        }
        targets[event.id] = event
        guard case .failed = event.state else {
            failures[event.id] = nil
            return
        }
        let build = event.build ?? ""
        guard event.notify, closedBuild != build else { return }
        if failureBuild != build {
            failures = [:]
            failureBuild = build
        }
        failures[event.id] = event
        showFailures()
    }

    /// Shows (or replaces) the one notice of ``failures``, unless the closed build is still being read.
    private func showFailures() {
        guard closedRead == nil, let build = failureBuild, let toast = Self.noticeToast(Array(failures.values)) else { return }
        let previous = shown
        // The same window replaces the previous toast in place (its handle ends `replaced`, which
        // is no close).
        guard let handle = showNotice(Notice(toast: toast, closed: { [weak self] in self?.close(build) })) else { return }
        shown = handle
        // One shown in another window goes: one notice at a time. Replaced, not closed by the person.
        if let previous, previous !== handle, !previous.isDismissed {
            previous.onDismiss = nil
            previous.dismiss()
        }
    }

    /// The person closed the notice of `build`: no notice for it again, also after a relaunch. A
    /// notice of that build shown since (a failure that came while the close settled) goes too.
    func close(_ build: String) {
        closedBuild = build
        if failureBuild == build {
            failures = [:]
            if let shown, !shown.isDismissed {
                shown.onDismiss = nil
                shown.dismiss()
            }
            shown = nil
        }
        guard let file = closedNoticeFile else { return }
        let before = closedWrite
        // task-owner: the board (`closedWrite`); one small write off the main actor after the one before, then it ends
        closedWrite = Task {
            await before?.value
            await Self.writeClosed(build, to: file)
        }
    }

    /// Settings > Updates' row of other machines: each that cannot update in place, then each whose
    /// update failed, as one line each; nil when none. Read when the card shows, and watched while
    /// it shows (`cmux.settings.channels.machines.changed`).
    ///
    /// A machine that cannot update in place has an Update button (``OtherMachine/canUpdate``,
    /// the policy's ``DaemonUpdatePolicy/retry(_:)``). Once clicked, its line says it is updating
    /// until the update ends: updated, it leaves the row; still unable or failed, its line returns.
    public var otherMachines: (title: String, lines: [String], machines: [OtherMachine])? {
        let events = targets.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        var machines: [OtherMachine] = []
        for event in events {
            switch event.state {
            case .cannotUpdate(let reason):
                machines.append(OtherMachine(id: event.id, line: reason, canUpdate: true))
            case .offline:
                machines.append(OtherMachine(id: event.id, line: Self.offlineLine(event.displayName), canUpdate: false))
            case .updating where clicked.contains(event.id), .retrying where clicked.contains(event.id):
                machines.append(OtherMachine(id: event.id, line: Self.updatingLine(event.displayName), canUpdate: false))
            default:
                break
            }
        }
        machines += events.compactMap { event in Self.notice(event).map { OtherMachine(id: event.id, line: $0, canUpdate: false) } }
        guard !machines.isEmpty else { return nil }
        return (String(localized: "agentPane.daemonUpdate.machines.title", defaultValue: "Other machines", bundle: .module),
                machines.map(\.line), machines)
    }

    /// One line of ``otherMachines``: the machine's target id, its text, and whether it has an
    /// Update button.
    public struct OtherMachine: Sendable, Equatable {
        public var id: String
        public var line: String
        public var canUpdate: Bool
    }

    /// The person clicked Update on machine `id` (``otherMachines``): its line says it is updating
    /// while the policy runs it. False (and no change) when `retry` refused it.
    @discardableResult
    public func update(_ id: String, retry: (String) async -> Bool) async -> Bool {
        guard case .cannotUpdate = targets[id]?.state, await retry(id) else { return false }
        clicked.insert(id)
        return true
    }

    /// The Update button of a machine in ``otherMachines``.
    public nonisolated static var updateLabel: String {
        String(localized: "agentPane.daemonUpdate.machines.update", defaultValue: "Update", bundle: .module)
    }

    /// Why an Update click did not run: the machine is gone from this run, or updates of other
    /// machines are off.
    public nonisolated static var updateRefused: String {
        String(localized: "agentPane.daemonUpdate.machines.updateRefused",
               defaultValue: "This machine can't be updated now. Try again once it's connected.", bundle: .module)
    }

    /// The row's "updating" line of machine `name`.
    nonisolated static func updatingLine(_ name: String) -> String {
        String(format: String(localized: "agentPane.daemonUpdate.machines.updating", defaultValue: "Updating %@ to this Mac's build…",
                              bundle: .module), name)
    }

    /// The row's line of machine `name` while it is offline.
    nonisolated static func offlineLine(_ name: String) -> String {
        String(format: String(localized: "agentPane.daemonUpdate.machines.offline", defaultValue: "%@ is offline; it will update when it's back",
                              bundle: .module), name)
    }

    /// The tooltip line of target `id`, nil when it has no update state.
    public func detail(id: String) -> String? {
        targets[id].map { Self.line($0.state) }
    }

    /// The tooltip line of the ssh machine `host` (`SSHDestination.host`), nil when no target of
    /// that host has an update state. O(targets): a handful of machines.
    public func detail(sshHost host: String) -> String? {
        let host = host.lowercased()
        // One pass; of several targets on one host, the lowest id, so the line never flips between them.
        var match: DaemonUpdateEvent?
        for event in targets.values where event.sshHost?.lowercased() == host {
            if match.map({ event.id < $0.id }) ?? true { match = event }
        }
        return match.map { Self.line($0.state) }
    }

    public nonisolated static func line(_ state: DaemonUpdateEvent.State) -> String {
        switch state {
        case .updating:
            String(localized: "agentPane.daemonUpdate.updating", defaultValue: "Updating to this Mac's build…", bundle: .module)
        case .retrying:
            String(localized: "agentPane.daemonUpdate.retrying", defaultValue: "Update will try again soon", bundle: .module)
        case .offline:
            String(localized: "agentPane.daemonUpdate.offline", defaultValue: "Offline; it will update when it's back", bundle: .module)
        case .updated(let build):
            String(format: String(localized: "agentPane.daemonUpdate.updated", defaultValue: "Updated to %@", bundle: .module), build)
        case .failed(let reason, false):
            String(format: String(localized: "agentPane.daemonUpdate.failed", defaultValue: "Update failed: %@", bundle: .module), reason)
        case .failed(let reason, true):
            String(format: String(localized: "agentPane.daemonUpdate.rolledBack", defaultValue: "Update rolled back: %@", bundle: .module), reason)
        case .cannotUpdate(let reason):
            reason
        case .cleared:
            // Never on the board: `apply` drops the target.
            ""
        }
    }

    /// The id of the one failure toast: each new failure replaces it in place.
    nonisolated static let noticeID = "daemon-update.failures"

    /// The one toast of `failures` (failed or rolled-back updates; other states are left out), nil
    /// when none: one machine's headline ("Couldn't update A", "A kept its previous build") with its
    /// bare reason as the detail, or "Couldn't update A and B" with each machine's notice as a line
    /// of the detail (each line names its machine and says whether it rolled back, which the
    /// headline does not). The detail is the tooltip and what Details shows in the toast (Leo 2026-10-29: "the FUCKING details are FUCKING
    /// STUPID BECAUSE IT TAKES YOU TO FUCKING SETTINGS????").
    nonisolated static func noticeToast(_ failures: [DaemonUpdateEvent]) -> CmuxToast? {
        let shown = failures.compactMap { event in notice(event).map { (event, $0) } }
            .sorted { $0.0.displayName.localizedStandardCompare($1.0.displayName) == .orderedAscending }
        guard let first = shown.first else { return nil }
        let action = CmuxToast.Action.details(String(localized: "agentPane.daemonUpdate.notice.details", defaultValue: "Details",
                                                     bundle: .module))
        guard shown.count > 1 else {
            return CmuxToast(id: noticeID, message: headline(first.0), detail: reason(first.0), action: action,
                             duration: CmuxToast.untilClosed)
        }
        let names = ListFormatter.localizedString(byJoining: shown.map(\.0.displayName))
        let message = String(format: String(localized: "agentPane.daemonUpdate.notice.several", defaultValue: "Couldn't update %@",
                                            bundle: .module), names)
        return CmuxToast(id: noticeID, message: message, detail: shown.map(\.1).joined(separator: "\n"), action: action,
                         duration: CmuxToast.untilClosed)
    }

    /// The headline of one machine's failed or rolled-back update, with no reason: the reason
    /// (``notice(_:)``) is the toast's detail.
    nonisolated static func headline(_ event: DaemonUpdateEvent) -> String {
        if case .failed(_, true) = event.state {
            return String(format: String(localized: "agentPane.daemonUpdate.notice.rolledBackHeadline",
                                         defaultValue: "%@ kept its previous build", bundle: .module), event.displayName)
        }
        return String(format: String(localized: "agentPane.daemonUpdate.notice.headline", defaultValue: "Couldn't update %@",
                                     bundle: .module), event.displayName)
    }

    /// The reason a failed or rolled-back update gave, alone (one machine's toast detail, under its
    /// headline); nil for any other state.
    nonisolated static func reason(_ event: DaemonUpdateEvent) -> String? {
        if case .failed(let reason, _) = event.state { return reason }
        return nil
    }

    /// The text of a failed or rolled-back update's toast; nil for any other state.
    nonisolated static func notice(_ event: DaemonUpdateEvent) -> String? {
        switch event.state {
        case .failed(let reason, false):
            String(format: String(localized: "agentPane.daemonUpdate.notice.failed", defaultValue: "Couldn't update %1$@: %2$@",
                                  bundle: .module), event.displayName, reason)
        case .failed(let reason, true):
            String(format: String(localized: "agentPane.daemonUpdate.notice.rolledBack",
                                  defaultValue: "%1$@ kept its previous build: %2$@", bundle: .module), event.displayName, reason)
        default: nil
        }
    }
}
