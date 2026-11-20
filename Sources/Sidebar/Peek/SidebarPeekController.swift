import AppKit
import CmuxSidebar
import Combine
import SwiftUI

/// Drives the collapsed sidebar's hover-reveal for one window.
///
/// Owns the timers and the published presentation flag; every transition
/// decision belongs to `SidebarPeekMachine`, which is pure and lives in
/// `CmuxSidebar`. This type does nothing but turn machine effects into
/// cancellable tasks and republish the resulting phase.
@MainActor
final class SidebarPeekController: ObservableObject {
    /// Whether the floating panel should be mounted and hit-testable.
    @Published private(set) var presentsPanel = false

    private var state = SidebarPeekState.idle
    private var machine = SidebarPeekMachine(policy: .default)
    private var dwellTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?

    /// The timing and behaviour policy in force.
    var policy: SidebarPeekPolicy {
        machine.policy
    }

    /// Replaces the policy, for example after a settings change.
    ///
    /// - Parameter policy: The new timings and behaviour flags.
    func setPolicy(_ policy: SidebarPeekPolicy) {
        // The policy is not published, but whether peek is on decides if
        // the card's window is mounted at all (`needsPeekPanel`).
        if policy.isEnabled != machine.policy.isEnabled {
            objectWillChange.send()
        }
        machine = SidebarPeekMachine(policy: policy)
#if DEBUG
        Self.installDebugTrigger(for: self)
#endif
        guard !policy.isEnabled else { return }
        send(.escapePressed)
    }

#if DEBUG
    /// When the latest activation-control hover arrived, for the probe.
    static var debugLastHoverUptime: CFTimeInterval?
    private static var debugTargets: [ObjectIdentifier: () -> SidebarPeekController?] = [:]
    private static var isDebugTriggerRegistered = false

    /// `notifyutil -p com.cmuxterm.debug.sidebar-peek` alternates a titlebar
    /// toggle hover enter and exit on every window, for measuring the reveal.
    private static func installDebugTrigger(for controller: SidebarPeekController) {
        guard SidebarNavigationTimings.isEnabled else { return }
        debugTargets[ObjectIdentifier(controller)] = { [weak controller] in controller }
        guard !isDebugTriggerRegistered else { return }
        isDebugTriggerRegistered = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        for target in SidebarPeekController.debugTargets.values {
                            guard let controller = target() else { continue }
                            if controller.presentsPanel {
                                controller.pointerExitedEdge()
                            } else {
                                controller.pointerEnteredActivationControl()
                            }
                        }
                    }
                }
            },
            "com.cmuxterm.debug.sidebar-peek" as CFString,
            nil,
            .deliverImmediately
        )
    }
#endif

    // MARK: - Events

    func pointerEnteredEdge() {
        SidebarNavigationTimings.begin("peek")
        send(.pointerEnteredEdge)
    }
    /// Edge-enter with the dwell skipped: hovering an activation control (the
    /// titlebar's sidebar toggle) is already a deliberate act, so the reveal
    /// starts the moment the pointer lands instead of after the edge dwell.
    func pointerEnteredActivationControl() {
#if DEBUG
        Self.debugLastHoverUptime = CACurrentMediaTime()
#endif
        SidebarNavigationTimings.begin("peek")
        send(.pointerEnteredEdge)
        send(.dwellElapsed)
    }
    func pointerExitedEdge() {
        SidebarNavigationTimings.cancel("peek")
        send(.pointerExitedEdge)
    }
    func dragEnteredEdge() { send(.dragEnteredEdge) }
    func workspaceActivated() { send(.workspaceActivated) }
    func escapePressed() { send(.escapePressed) }
    func sidebarDocked() { send(.sidebarDocked) }
    func sidebarCollapsed() { send(.sidebarCollapsed) }

    /// Adds a hold, keeping the panel open regardless of pointer position.
    func acquire(_ hold: SidebarPeekHold) { send(.holdAcquired(hold)) }

    /// Removes a hold.
    func release(_ hold: SidebarPeekHold) { send(.holdReleased(hold)) }

    /// Cancels every timer, for window teardown.
    func stop() {
        dwellTask?.cancel()
        dwellTask = nil
        graceTask?.cancel()
        graceTask = nil
        state = .idle
        presentsPanel = false
    }

    // MARK: - Machine plumbing

    private func send(_ event: SidebarPeekEvent) {
        let effects = machine.apply(event, to: &state)
#if DEBUG
        cmuxDebugLog("sidebar.peek event=\(event) phase=\(state.phase.rawValue) holds=\(state.holds.rawValue)")
#endif
        for effect in effects {
            perform(effect)
        }
        // Publishing unconditionally would invalidate the window body on every
        // pointer crossing of the edge strip, most of which change nothing.
        if presentsPanel != state.presentsPanel {
            presentsPanel = state.presentsPanel
            if presentsPanel {
                SidebarNavigationTimings.end("peek")
            }
        }
    }

    private func perform(_ effect: SidebarPeekEffect) {
        switch effect {
        case .startDwellTimer:
            dwellTask?.cancel()
            dwellTask = schedule(after: machine.policy.dwell) { [weak self] in
                self?.send(.dwellElapsed)
            }
        case .cancelDwellTimer:
            dwellTask?.cancel()
            dwellTask = nil
        case .startGraceTimer:
            graceTask?.cancel()
            graceTask = schedule(after: machine.policy.grace) { [weak self] in
                self?.send(.graceElapsed)
            }
        case .cancelGraceTimer:
            graceTask?.cancel()
            graceTask = nil
        }
    }

    private func schedule(
        after duration: Duration,
        _ body: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            // A cancelled sleep throws, which is the cancellation path: the
            // body must not run for a timer that was superseded.
            guard (try? await Task.sleep(for: duration)) != nil else { return }
            body()
        }
    }
}
