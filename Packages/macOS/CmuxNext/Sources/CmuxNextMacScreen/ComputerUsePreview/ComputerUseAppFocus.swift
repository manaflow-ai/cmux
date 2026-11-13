// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
public import CmuxNextComputerUse
public import CmuxNextDaemon

/// The App's ``ComputerUseFocusing`` (Show Window, Focus Calling Terminal): the target app by pid,
/// the calling terminal through the same reveal as a tab link.
@MainActor
public final class ComputerUseAppFocus: ComputerUseFocusing {
    private let stores: @MainActor () -> [DaemonStore]
    private let reveal: @MainActor (String) -> Bool

    /// - Parameters:
    ///   - stores: Every machine's daemon store, this Mac's first.
    ///   - reveal: Reveals a tab (by its id) in its window, as a tab link does.
    public init(stores: @escaping @MainActor () -> [DaemonStore], reveal: @escaping @MainActor (String) -> Bool) {
        self.stores = stores
        self.reveal = reveal
    }

    public func raiseTarget(of session: ComputerUseLiveSession) -> Bool { session.activateTarget() }

    public func revealCallingTerminal(of session: ComputerUseLiveSession) -> Bool {
        guard let terminal = session.terminalID else { return false }
        for store in stores() {
            if let tab = store.tab(terminal: TerminalID(rawValue: terminal)) ?? store.tab(terminalResource: ResourceID(rawValue: terminal)) {
                return reveal(tab.id)
            }
        }
        return false
    }
}

extension ComputerUseLiveSession {
    /// Brings the app the session acts on to the front (Show Window). The host reports the pid it
    /// acted on; a recycled pid of another app is refused by the bundle id.
    @MainActor public func activateTarget() -> Bool {
        guard let target, let pid = target.pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              target.bundleID == nil || app.bundleIdentifier == target.bundleID else { return false }
        return app.activate(options: [])
    }
}
