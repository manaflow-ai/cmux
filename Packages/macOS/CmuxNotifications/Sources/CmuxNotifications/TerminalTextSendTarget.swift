public import Foundation

/// The workspace the ``TerminalTextSendCoordinator`` delivers text into, plus the
/// readiness-signal registration primitives it needs.
///
/// The coordinator owns the readiness decision logic (resolution precedence, the
/// resolved latch, the surface-match gating, cleanup ordering, the timeout). The
/// target only supplies the app-platform primitives those decisions are built
/// on: resolving the current panel and registering observers for the three
/// readiness signals plus the timeout. The app-side conformer wraps
/// `Workspace.panelsPublisher` (Combine), the ghostty `NotificationCenter`
/// signals, and `DispatchQueue.main.asyncAfter`, returning a
/// ``TerminalTextSendCancellable`` token for each so the coordinator can tear
/// them down without knowing the backing mechanism.
@MainActor
public protocol TerminalTextSendTarget: AnyObject {
    /// Identity of the target workspace, used to match the workspace-scoped
    /// readiness notifications and for DEBUG tracing parity.
    var workspaceID: UUID { get }

    /// Resolves the panel text should be delivered to right now: the preferred
    /// panel when one was requested, otherwise the focused terminal panel.
    /// Mirrors `AppDelegate.resolveTerminalPanelForTextSend(in:preferredPanelId:)`.
    func resolveSendPanel(preferredPanelID: UUID?) -> (any TerminalTextSendPanel)?

    /// Registers `handler` to run on every panels-set change for this workspace.
    /// Wraps `Workspace.panelsPublisher`.
    func observePanelsChanged(_ handler: @escaping @MainActor () -> Void) -> any TerminalTextSendCancellable

    /// Registers `handler` for the workspace-scoped terminal-surface-ready signal.
    /// `handler` receives the surface id that became ready (nil when absent).
    /// Wraps `Notification.Name.terminalSurfaceDidBecomeReady` filtered to this
    /// workspace.
    func observeSurfaceReady(_ handler: @escaping @MainActor (UUID?) -> Void) -> any TerminalTextSendCancellable

    /// Registers a DEBUG-only observer for the ghostty focus signal, used purely
    /// for reactGrab pasteback tracing. `handler` receives the focused surface id.
    /// Wraps `Notification.Name.ghosttyDidFocusSurface` filtered to this workspace.
    func observeDidFocusSurface(_ handler: @escaping @MainActor (UUID) -> Void) -> any TerminalTextSendCancellable

    /// Registers a DEBUG-only observer for the ghostty first-responder signal,
    /// used purely for reactGrab pasteback tracing. Wraps
    /// `Notification.Name.ghosttyDidBecomeFirstResponderSurface` filtered to this
    /// workspace.
    func observeDidBecomeFirstResponderSurface(_ handler: @escaping @MainActor (UUID) -> Void) -> any TerminalTextSendCancellable

    /// Schedules `handler` to run after `seconds`, returning a token whose
    /// cancellation prevents the run. Wraps `DispatchQueue.main.asyncAfter`.
    func scheduleTimeout(after seconds: TimeInterval, _ handler: @escaping @MainActor () -> Void) -> any TerminalTextSendCancellable
}

/// A teardown token for one readiness observer or the timeout. Cancellation is
/// idempotent. Wraps a Combine `AnyCancellable`, an `NSObjectProtocol` observer
/// removal, or a `DispatchWorkItem` cancel app-side.
@MainActor
public protocol TerminalTextSendCancellable: AnyObject {
    /// Tears down the underlying observer or scheduled work. Safe to call twice.
    func cancel()
}
