import AppKit
import CmuxNextDesign
import Foundation
public import Observation

/// The latest update state of each ``DaemonUpdateTarget``, as ``DaemonUpdatePolicy`` reports it:
/// an ssh machine's sidebar tooltip shows its line (``detail(sshHost:)``), another surface looks a
/// target up by id (``detail(id:)``); a failed or rolled-back update shows a toast that stays until
/// closed (``notice(_:)``).
@MainActor @Observable
public final class DaemonUpdateBoard {
    // lint:allow one board per app process: the policy writes it, the sidebar of every window reads it
    public static let shared = DaemonUpdateBoard()

    /// The latest event per target id.
    public private(set) var targets: [String: DaemonUpdateEvent] = [:]

    /// Shows a notice's toast in the front window, unless replaced (tests). A process with no
    /// application (a test of the policy with a real board) shows nothing.
    @ObservationIgnored var showNotice: @MainActor (CmuxToast) -> Void = { toast in
        guard let app = NSApp as NSApplication?,
              let window = DaemonUpdateBoard.noticeWindow(key: app.keyWindow, main: app.mainWindow, ordered: app.orderedWindows)
        else { return }
        _ = CmuxToastCenter.shared.show(toast, in: window)
    }

    public init() {}

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
        guard event.state != .cleared else {
            targets[event.id] = nil
            return
        }
        targets[event.id] = event
        if event.notify, let toast = Self.noticeToast(event) { showNotice(toast) }
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
        case .updated(let build):
            String(format: String(localized: "agentPane.daemonUpdate.updated", defaultValue: "Updated to %@", bundle: .module), build)
        case .failed(let reason, false):
            String(format: String(localized: "agentPane.daemonUpdate.failed", defaultValue: "Update failed: %@", bundle: .module), reason)
        case .failed(let reason, true):
            String(format: String(localized: "agentPane.daemonUpdate.rolledBack", defaultValue: "Update rolled back: %@", bundle: .module), reason)
        case .cleared:
            // Never on the board: `apply` drops the target.
            ""
        }
    }

    /// The toast of a failed or rolled-back update, nil for any other state. Its id names the
    /// target and the build the update was to, so a later build's failure, or another machine
    /// with the same name and reason, is a toast of its own, never one the center replaces or
    /// keeps quiet. The same event again (one target, one build) replaces it in place.
    nonisolated static func noticeToast(_ event: DaemonUpdateEvent) -> CmuxToast? {
        notice(event).map { CmuxToast(id: "daemon-update.\(event.id).\(event.build ?? "")", message: $0, duration: CmuxToast.untilClosed) }
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
