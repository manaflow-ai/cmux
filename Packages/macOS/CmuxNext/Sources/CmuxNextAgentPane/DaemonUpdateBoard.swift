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

    /// Shows a notice's text; the front window's toast unless replaced (tests).
    @ObservationIgnored var showNotice: @MainActor (String) -> Void = { message in
        guard let window = DaemonUpdateBoard.noticeWindow(key: NSApp.keyWindow, main: NSApp.mainWindow, ordered: NSApp.orderedWindows,
                                                          visible: { $0.isVisible || $0.isMiniaturized }) else { return }
        _ = CmuxToastCenter.shared.show(CmuxToast(id: "daemon-update.\(message.hashValue)", message: message,
                                                  duration: CmuxToast.untilClosed), in: window)
    }

    public init() {}

    /// The window a notice goes to: the key window, else the main one, else the frontmost shown
    /// window that can be main. An update fails in the background, often while the app is not
    /// active, and AppKit then has no key or main window.
    static func noticeWindow(key: NSWindow?, main: NSWindow?, ordered: [NSWindow], visible: (NSWindow) -> Bool) -> NSWindow? {
        key ?? main ?? ordered.first { $0.canBecomeMain && visible($0) }
    }

    public func apply(_ event: DaemonUpdateEvent) {
        guard event.state != .cleared else {
            targets[event.id] = nil
            return
        }
        targets[event.id] = event
        if event.notify, let message = Self.notice(event) { showNotice(message) }
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

    /// The toast of a failed or rolled-back update; nil for any other state.
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
