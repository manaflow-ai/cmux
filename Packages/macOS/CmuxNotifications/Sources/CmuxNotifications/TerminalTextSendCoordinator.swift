public import Foundation

/// Delivers text to a workspace's terminal once a surface is ready, with a 3s
/// timeout. Lifted faithfully from `AppDelegate.sendTextWhenReady`.
///
/// A Coordinator (CONVENTIONS §2): it sequences the "send text when the surface
/// becomes ready" flow and owns the readiness decision logic. It does no I/O and
/// holds no UI state. The platform primitives it builds on (resolving the
/// current panel, the Combine panels signal, the ghostty `NotificationCenter`
/// readiness signals, and the `asyncAfter` timeout) are supplied through the
/// ``TerminalTextSendTarget`` seam, so the app's `Workspace`/`TerminalPanel`
/// types never enter the package. DEBUG reactGrab-pasteback tracing is emitted
/// through the optional ``TerminalTextSendTracing`` seam at the same points the
/// legacy body logged.
///
/// `@MainActor` because every readiness signal arrives on the main run loop and
/// `sendText`/focus are main-actor side effects, exactly as the legacy body ran.
@MainActor
public final class TerminalTextSendCoordinator {
    private let tracing: (any TerminalTextSendTracing)?

    /// Creates the coordinator. `tracing` is non-nil only in DEBUG builds running
    /// the reactGrab pasteback flow; production injects nil and all trace hooks
    /// are skipped.
    public init(tracing: (any TerminalTextSendTracing)? = nil) {
        self.tracing = tracing
    }

    /// Sends `text` to `target` when its terminal surface is ready.
    ///
    /// - When the resolved panel is agent-hibernated, sends immediately (the
    ///   recorder buffers without a live surface).
    /// - When the resolved panel already has a live surface, sends immediately.
    /// - Otherwise registers readiness observers and a 3s timeout, sending on the
    ///   first matching readiness signal and calling `onFailure` if the timeout
    ///   fires first.
    ///
    /// `preferredPanelID != nil` is the reactGrab pasteback flow, which also
    /// arms the focus/first-responder trace observers. `beforeSend` runs once,
    /// immediately before the (single) successful or attempted send.
    public func send(
        _ text: String,
        to target: any TerminalTextSendTarget,
        preferredPanelID: UUID? = nil,
        beforeSend: (() -> Void)? = nil,
        onFailure: (() -> Void)? = nil
    ) {
        let isReactGrabPasteback = preferredPanelID != nil

        if isReactGrabPasteback {
            let initialTargetPanel = target.resolveSendPanel(preferredPanelID: preferredPanelID)
            tracing?.sendStart(
                preferredPanelID: preferredPanelID,
                resolvedPanelID: initialTargetPanel?.panelID,
                surfaceReady: initialTargetPanel?.isSurfaceReady ?? false,
                textCount: text.count
            )
        }

        if let terminalPanel = target.resolveSendPanel(preferredPanelID: preferredPanelID),
           terminalPanel.isAgentHibernated {
            beforeSend?()
            if !terminalPanel.sendText(text) {
                onFailure?()
            }
            return
        }

        if let terminalPanel = target.resolveSendPanel(preferredPanelID: preferredPanelID),
           terminalPanel.isSurfaceReady {
            if isReactGrabPasteback {
                tracing?.sendImmediate(
                    targetPanelID: terminalPanel.panelID,
                    textCount: text.count
                )
            }
            beforeSend?()
            let didSend = terminalPanel.sendText(text)
            if isReactGrabPasteback, didSend {
                tracing?.sendSent(
                    targetPanelID: terminalPanel.panelID,
                    delayed: false,
                    textCount: text.count
                )
            }
            if !didSend {
                onFailure?()
            }
            return
        }

        target.resolveSendPanel(preferredPanelID: preferredPanelID)?.requestInputDemandSurfaceStartIfNeeded()

        var resolved = false
        var readyObserver: (any TerminalTextSendCancellable)?
        var focusObserver: (any TerminalTextSendCancellable)?
        var firstResponderObserver: (any TerminalTextSendCancellable)?
        var panelsObserver: (any TerminalTextSendCancellable)?
        var timeoutObserver: (any TerminalTextSendCancellable)?

        func cleanupObservers() {
            readyObserver?.cancel()
            focusObserver?.cancel()
            firstResponderObserver?.cancel()
            panelsObserver?.cancel()
        }

        func finishIfReady() {
            let terminalPanel = target.resolveSendPanel(preferredPanelID: preferredPanelID)
            if isReactGrabPasteback {
                tracing?.finishIfReady(
                    preferredPanelID: preferredPanelID,
                    resolvedPanelID: terminalPanel?.panelID,
                    surfaceReady: terminalPanel?.isSurfaceReady ?? false,
                    alreadyResolved: resolved
                )
            }
            guard !resolved,
                  let terminalPanel,
                  terminalPanel.isSurfaceReady else { return }
            resolved = true
            cleanupObservers()
            beforeSend?()
            let didSend = terminalPanel.sendText(text)
            if isReactGrabPasteback, didSend {
                tracing?.sendSent(
                    targetPanelID: terminalPanel.panelID,
                    delayed: true,
                    textCount: text.count
                )
            }
            if !didSend {
                onFailure?()
            }
        }

        panelsObserver = target.observePanelsChanged {
            if isReactGrabPasteback {
                self.tracing?.panelsChanged()
            }
            finishIfReady()
        }

        if isReactGrabPasteback {
            focusObserver = target.observeDidFocusSurface { candidateSurfaceID in
                self.tracing?.focusEvent(
                    surfaceID: candidateSurfaceID,
                    preferredPanelID: preferredPanelID
                )
            }
            firstResponderObserver = target.observeDidBecomeFirstResponderSurface { candidateSurfaceID in
                self.tracing?.firstResponderEvent(
                    surfaceID: candidateSurfaceID,
                    preferredPanelID: preferredPanelID
                )
            }
        }

        readyObserver = target.observeSurfaceReady { surfaceID in
            if isReactGrabPasteback {
                self.tracing?.surfaceReadyEvent(
                    surfaceID: surfaceID,
                    preferredPanelID: preferredPanelID
                )
            }
            if let preferredPanelID,
               let surfaceID,
               surfaceID != preferredPanelID {
                return
            }
            finishIfReady()
        }

        timeoutObserver = target.scheduleTimeout(after: 3.0) {
            if !resolved {
                resolved = true
                if isReactGrabPasteback {
                    self.tracing?.sendTimeout(preferredPanelID: preferredPanelID)
                }
                cleanupObservers()
                NSLog("Command send: surface not ready after 3.0s")
                onFailure?()
            }
        }
        _ = timeoutObserver
    }
}
