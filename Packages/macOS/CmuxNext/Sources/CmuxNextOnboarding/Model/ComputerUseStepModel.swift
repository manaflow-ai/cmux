public import Foundation
public import Observation

/// Computer Use setup: one window with a row per grant the helper app
/// needs. Allow opens that list in System Settings and docks a panel with
/// the helper app to drag in; when the grant lands the panel goes, the
/// window comes back to the front by itself and the next row becomes the
/// primary one. Nothing is asked twice.
@MainActor
@Observable
public final class ComputerUseStepModel {
    public private(set) var permissions: ComputerUsePermissions = .none
    /// The list the drag panel is helping with, while it shows.
    public private(set) var helping: ComputerUsePermissionPane?
    /// Allow found no Developer ID signed helper: computer use is
    /// unavailable in this build, and the window says so instead of
    /// offering an ad-hoc helper for a grant.
    public private(set) var unavailable = false
    /// How many times a grant landed while its drag panel showed, or the
    /// panel's back button closed it. The window comes back to the front on
    /// each one.
    public private(set) var comebacks = 0
    @ObservationIgnored let source: (any ComputerUsePermissionSource)?
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    /// Called by ``stop()`` (the window closed or the step left): the view takes its drag panel down at once.
    @ObservationIgnored var onStop: (@MainActor () -> Void)?

    init(source: (any ComputerUsePermissionSource)?) {
        self.source = source
    }

    /// Follows the helper's grants while the window shows.
    func start() {
        guard task == nil, let source else { return }
        let stream = source.permissions()
        task = Task { [weak self] in
            for await value in stream {
                // stop() cancels on the main actor, so a value already
                // buffered then is dropped here rather than applied late.
                guard let self, !Task.isCancelled else { return }
                apply(value)
            }
        }
    }

    private func apply(_ value: ComputerUsePermissions) {
        permissions = value
        if value.helperFailed { helping = nil }
        if let pane = helping, value.granted(pane) {
            helping = nil
            comebacks += 1
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        helping = nil
        onStop?()
    }

    /// The first grant still missing, in row order: the row whose Allow is
    /// the window's one primary action. Nil when every grant is on, or when
    /// no Allow can help (the helper failed or speaks another protocol).
    public var nextPane: ComputerUsePermissionPane? {
        guard !permissions.helperFailed, !permissions.helperVersionMismatch else { return nil }
        return ComputerUsePermissionPane.allCases.first { !permissions.granted($0) }
    }

    /// Whether `pane`'s Allow is the filled primary button: the next missing
    /// row, unless its drag panel already shows (then it waits, gray).
    public func isPrimary(_ pane: ComputerUsePermissionPane) -> Bool {
        pane == nextPane && helping != pane && !unavailable
    }

    /// Every grant is on: the window shows its done state.
    public var allGranted: Bool {
        !permissions.isOff && !permissions.helperFailed && !permissions.helperVersionMismatch
            && ComputerUsePermissionPane.allCases.allSatisfy { permissions.granted($0) }
    }

    /// Allow: the pane in System Settings, with the drag panel docked to it.
    /// Without a Developer ID signed helper there is nothing a grant would
    /// help: no list opens, no panel shows, and the window says computer use
    /// is unavailable in this build.
    public func allow(_ pane: ComputerUsePermissionPane) {
        guard let source, !permissions.granted(pane) else { return }
        guard source.helperAppURL != nil else {
            unavailable = true
            helping = nil
            return
        }
        unavailable = false
        // Computer Use is off: the person's Allow turns it on, so the helper
        // that needs the grant starts and its rows turn Done by themselves.
        if permissions.isOff { source.enable() }
        source.openSettings(pane)
        helping = pane
    }

    /// Return in the window: the primary row's Allow. False when no row is
    /// primary (all done, or nothing to allow).
    @discardableResult
    public func allowNext() -> Bool {
        guard let pane = nextPane, isPrimary(pane) else { return false }
        allow(pane)
        return true
    }

    /// Restarts a helper that did not answer setup.
    public func restart() {
        guard permissions.helperFailed else { return }
        unavailable = false
        helping = nil
        source?.restart()
    }

    /// The panel's back button: the panel goes and the window comes back to
    /// the front, its row primary again.
    public func dismissHelper() {
        guard helping != nil else { return }
        helping = nil
        comebacks += 1
    }

    /// The helper app was dropped somewhere: read the grants again, since
    /// a drop into the list is how the grant usually lands.
    public func helperDropped() {
        guard helping != nil else { return }
        source?.recheck()
    }

    public var helperAppURL: URL? { source?.helperAppURL }
}
