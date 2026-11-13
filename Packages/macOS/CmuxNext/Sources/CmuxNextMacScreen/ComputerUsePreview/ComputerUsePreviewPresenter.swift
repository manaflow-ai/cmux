// SPDX-License-Identifier: GPL-3.0-or-later
public import AppKit
public import CmuxNextComputerUse
public import CmuxNextActions
import CmuxNextCompat
import CmuxNextWakeups
import os

private let previewPresenterLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use-preview")

/// What the live preview reads from the App: the setting and the surface the person looks at. The App conforms (AppServices); tests can stand in.
@MainActor
public protocol ComputerUsePreviewHost: AnyObject {
    /// `computerUse.livePreview` now.
    var computerUseLivePreviewEnabled: Bool { get }
    /// The surface the person looks at (the focused tab of the key window's shown workspace, while
    /// cmux is the active app), with the view the preview docks over; nil when it is no agent's.
    func computerUsePreviewFocus() -> (surface: ComputerUsePreviewSurface, host: NSView)?
}

/// The live preview of an agent's Computer Use (`computerUse.livePreview`, on by default), as the
/// ChatGPT app shows its Computer Use picture: a live video of the window the agent drives, docked
/// at the top right of that agent's own surface (its terminal pane or its chat), while that surface
/// is the one the person looks at in the key window of the active app. cmux Remote streams the
/// window (it holds the Screen Recording grant and refuses private apps); the app only shows it.
///
/// Nothing is captured unless a preview shows: the stream opens with it and closes when the person
/// looks elsewhere, hides it, turns the setting off, or the agent finishes (a short completion
/// effect, then it goes away). What the person chose (expanded, hidden here, hidden for every
/// active agent, the corner and the size) is kept in memory for this run.
@MainActor
public final class ComputerUsePreviewPresenter {
    private let remote: CmuxRemoteService
    private let registry: ActionRegistry
    private weak var host: (any ComputerUsePreviewHost)?
    let rules = ComputerUsePreviewRules()
    private var started = false

    /// The preview on screen now: its surface, session, overlay and stream.
    private struct Shown {
        var surface: ComputerUsePreviewSurface
        var session: String
        weak var host: NSView?
        let overlay: ComputerUsePreviewOverlay
        var stream: ComputerUsePreviewStream?
        /// The stream said its window's app is private: no picture is shown until it says
        /// `streaming` or `still` again (the channel stays open; cmux Remote looks every 500 ms).
        var blocked = false
    }
    /// The picture's long side asked of cmux Remote: the card at 2x its largest size, the expanded
    /// view at the wire's largest.
    private static let cardStreamLongSide = Int(ComputerUsePreviewLayout.maximumLongSide * 2)
    private static let expandedStreamLongSide = 1600
    /// The wait before the channel opens again after it closed: 1 s, doubling to 30 s while cmux
    /// Remote keeps refusing (an older host, or no worker), back to 1 s once a picture comes.
    private var retryDelay: Duration = .seconds(1)
    private static let maximumRetryDelay: Duration = .seconds(30)
    /// A retry is scheduled: the stream stays closed until then.
    private var retrying = false
    /// The current outage was logged (once per outage).
    private var outageLogged = false
    private var shown: Shown?
    /// What the person chose per surface (a new surface starts as a card).
    private var choices: [ComputerUsePreviewSurface: ComputerUsePreviewPresentation] = [:]
    private var corner = ComputerUsePreviewLayout.Corner.topRight
    private var longSide = ComputerUsePreviewLayout.defaultLongSide
    private let linger = DemandTimer(owner: "computer-use.preview.linger")
    private let reopen = DemandTimer(owner: "computer-use.preview.reopen")
    private var updateQueued = false
    private var escapeMonitor: Any?
    private var observation: Task<Void, Never>?

    /// - Parameters:
    ///   - remote: cmux Remote: the agents' sessions and the preview channel.
    ///   - registry: The actions (Show Window runs `computerUseFocus`).
    ///   - host: The App (held weakly).
    public init(remote: CmuxRemoteService, registry: ActionRegistry, host: any ComputerUsePreviewHost) {
        self.remote = remote
        self.registry = registry
        self.host = host
    }

    /// Follows the agents' activity and the setting; the App calls ``focusChanged()`` when a window's
    /// focus, the key window or the app's activation changes.
    public func start() {
        guard !started else { return }
        started = true
        let state = remote.computerUse
        observation = Task { [weak self] in
            for await _ in ObservationStream({ [weak self] () -> String in
                let enabled = self?.host?.computerUseLivePreviewEnabled ?? true
                let sessions = state.sessions.map { "\($0.id)#\($0.lastAction.timeIntervalSince1970)#\($0.stopped)" }
                return "\(enabled)|" + sessions.joined(separator: ",")
            }) {
                self?.update()
            }
        }
    }

    /// A window's focus moved, or the app or its key window changed: look again
    /// on the next turn, once for a burst.
    public func focusChanged() {
        guard started, !updateQueued else { return }
        updateQueued = true
        MainDelivery().later { [weak self] in
            self?.updateQueued = false
            self?.update()
        }
    }

    // MARK: Deciding

    private func update() {
        let now = Date()
        let enabled = host?.computerUseLivePreviewEnabled ?? false
        let focused = host?.computerUsePreviewFocus()
        let candidates = remote.computerUse.sessions.map {
            ComputerUsePreviewCandidate(session: $0.id, agent: $0.agent, appName: $0.appName, lastAction: $0.lastAction, stopped: $0.stopped)
        }
        let pick = rules.session(for: focused?.surface, among: candidates, enabled: enabled, now: now)
        guard let pick, let focused else {
            // The setting is off, or the person looks elsewhere: nothing shows, nothing streams at
            // once. Still looking at the same surface, the agent finished (it stopped, ended, or has
            // not acted for a while): the completion effect plays first, as ChatGPT's does.
            let finished = enabled && shown.map { focused?.surface == $0.surface } == true
            dismiss(completing: finished)
            return
        }
        if let lingers = rules.lingersUntil(pick, now: now) {
            linger.schedule(after: .milliseconds(Int64((lingers.timeIntervalSince(now) * 1000).rounded(.up)) + 50)) { @MainActor [weak self] in
                self?.update()
            }
        }
        show(pick, on: focused)
    }

    private func presentation(for surface: ComputerUsePreviewSurface) -> ComputerUsePreviewPresentation {
        choices[surface] ?? .card
    }

    // MARK: The menu bar's Live Preview row

    /// Whether session `session`'s preview may show (true) or the person hid it (false); nil when
    /// no preview applies: the setting is off, or the session names no terminal or chat.
    public func isShown(session: String) -> Bool? {
        guard host?.computerUseLivePreviewEnabled ?? false,
              let surface = ComputerUsePreviewSurface(session: session) else { return nil }
        return presentation(for: surface) != .hidden
    }

    /// Live Preview: Show or Hide for session `session`, as the preview's own Hide and chip do.
    public func set(session: String, shown: Bool) {
        guard let surface = ComputerUsePreviewSurface(session: session) else { return }
        choices[surface] = shown ? .card : .hidden
        update()
    }

    // MARK: Showing

    private func show(_ pick: ComputerUsePreviewCandidate, on focused: (surface: ComputerUsePreviewSurface, host: NSView)) {
        if let current = shown, current.surface != focused.surface || current.session != pick.session || current.host !== focused.host {
            dismiss(completing: false)
        }
        if shown == nil {
            guard let container = focused.host.superview else { return }
            let overlay = ComputerUsePreviewOverlay()
            overlay.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(overlay, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: focused.host.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: focused.host.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: focused.host.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: focused.host.bottomAnchor),
            ])
            overlay.place(corner: corner, longSide: longSide)
            overlay.onRequest = { [weak self] request in self?.handle(request) }
            shown = Shown(surface: focused.surface, session: pick.session, host: focused.host, overlay: overlay)
        }
        guard var current = shown else { return }
        let presentation = presentation(for: current.surface)
        current.overlay.isHidden = current.blocked
        current.overlay.present(presentation)
        // The stream runs while the preview is up, a blocked one too (cmux Remote sends nothing but
        // its status, and says when the window may show again); a hidden preview (a chip) streams
        // nothing. The expanded view asks for a larger picture.
        let side = presentation == .expanded ? Self.expandedStreamLongSide : Self.cardStreamLongSide
        if presentation == .hidden {
            current.stream?.stop()
            current.stream = nil
        } else if current.stream?.requestedLongSide != side, !retrying {
            current.stream?.stop()
            current.stream = openStream(for: pick.session, longSide: side, overlay: current.overlay)
        }
        shown = current
        followEscape(presentation == .expanded)
    }

    private func openStream(for session: String, longSide: Int, overlay: ComputerUsePreviewOverlay) -> ComputerUsePreviewStream {
        let stream = ComputerUsePreviewStream(session: session, longSide: longSide) { [weak self] event in
            self?.streamEvent(event, session: session)
        }
        overlay.show(video: stream.displayLayer)
        stream.start(remote: remote)
        return stream
    }

    private func streamEvent(_ event: ComputerUsePreviewStream.Event, session: String) {
        guard var current = shown, current.session == session else { return }
        switch event {
        case .status(let status):
            if let width = status.width, let height = status.height, width > 0, height > 0 {
                current.overlay.aspect = CGFloat(width) / CGFloat(height)
            }
            switch status.state {
            case .streaming, .still:
                if status.state == .streaming { current.overlay.show(still: nil) }
                current.blocked = false
                retryDelay = .seconds(1)
                outageLogged = false
            case .blocked:
                // A private window shows nothing at all, not even the last still, until cmux Remote
                // says it may show again (a later paused or no_window status does not).
                current.blocked = true
                current.overlay.show(still: nil)
            case .noWindow, .paused:
                break
            }
            current.overlay.isHidden = current.blocked
        case .still(let data):
            current.overlay.show(still: data)
        case .closed:
            // cmux Remote went away or refused (an older host has no such channel): try again,
            // waiting longer each time up to 30 s, and say so once.
            current.stream = nil
            if !outageLogged {
                outageLogged = true
                previewPresenterLogger.notice("Computer Use preview: the channel closed; retrying with backoff")
            }
            retrying = true
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, Self.maximumRetryDelay)
            reopen.schedule(after: delay) { @MainActor [weak self] in
                self?.retrying = false
                self?.update()
            }
        }
        shown = current
    }

    private func dismiss(completing: Bool) {
        linger.cancel()
        reopen.cancel()
        retrying = false
        followEscape(false)
        guard let current = shown else { return }
        shown = nil
        current.stream?.stop()
        guard completing else { return current.overlay.removeFromSuperview() }
        current.overlay.complete { current.overlay.removeFromSuperview() }
    }

    // MARK: The person's requests

    private func handle(_ request: ComputerUsePreviewRequest) {
        guard let current = shown else { return }
        switch request {
        case .expand: choices[current.surface] = presentation(for: current.surface).after(.expand)
        case .collapse: choices[current.surface] = presentation(for: current.surface).after(.collapse)
        case .hideHere: choices[current.surface] = .hidden
        case .hideEverywhere:
            // "Hide for All Active Chats": every surface with an agent session now; an agent that
            // starts later shows its preview again.
            for session in remote.computerUse.sessions where !session.stopped {
                if let surface = ComputerUsePreviewSurface(session: session.id) { choices[surface] = .hidden }
            }
            choices[current.surface] = .hidden
        case .show:
            choices[current.surface] = .card
        case .moved(let corner):
            self.corner = corner
            current.overlay.place(corner: corner, longSide: longSide)
        case .resized(let side):
            longSide = side
            current.overlay.place(corner: corner, longSide: side)
        case .showWindow:
            showWindow(of: current.session)
        }
        update()
    }

    /// Show Window: the same `computerUseFocus` action as the menu bar's row (the window comes
    /// forward in its app, then the app): the one time the preview moves focus, because the person asked.
    private func showWindow(of session: String) {
        registry.perform("computerUseFocus", invocation: ActionInvocation(arguments: ["session": .string(session)]))
    }

    /// Escape closes the expanded view only while the pointer is over its picture. Anywhere else it
    /// goes on to the surface: in the agent's own terminal Escape interrupts Claude Code or Codex,
    /// and a preview must never swallow that. A click anywhere closes the expanded view too.
    private func followEscape(_ on: Bool) {
        if on, escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self, let current = self.shown, let window = current.overlay.window,
                      event.window === window, self.presentation(for: current.surface) == .expanded,
                      current.overlay.expandedPictureContains(windowPoint: window.mouseLocationOutsideOfEventStream) else { return event }
                self.handle(.collapse)
                return nil
            }
        } else if !on, let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}
