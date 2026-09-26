import AppKit
import CmuxDictation
import CmuxSettings
import Foundation

/// Owns the fn-key dictation trigger: global flag-change monitors, the pure
/// gesture classifier, the session controller, and the HUD.
///
/// Composition-root owned by `AppDelegate` (no singleton); monitors are
/// installed at `start()` but every trigger is gated on the
/// `dictation.beta.enabled` settings key, so nothing captures the key or
/// touches the microphone while the beta toggle is off.
@MainActor
final class DictationCoordinator {
    /// Whether the Settings beta toggle enables the trigger.
    static var isEnabled: Bool {
        let key = SettingCatalog().betaFeatures.dictation
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey))
            ?? key.defaultValue
    }

    /// Pure double-tap / hold classifier fed by the monitors.
    private var machine = DictationTriggerStateMachine()
    /// Timer promoting a press to a hold once the threshold elapses.
    private var holdTask: Task<Void, Never>?
    /// Installed monitors; `nil` before ``start()``.
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// The session controller; created lazily so the toggle alone never links
    /// Speech/AVFoundation startup work into launch.
    private lazy var controller = DictationController(
        makeSession: { SpeechDictationEngine() },
        sink: DictationSurfaceTextSink(),
        authorization: .systemLive
    )
    /// Floating state HUD driven by the controller's phase stream.
    private lazy var hud = DictationHUDController(controller: controller)
    /// Phase consumer keeping the HUD lifecycle in sync.
    private var phaseTask: Task<Void, Never>?

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        holdTask?.cancel()
        phaseTask?.cancel()
    }

    /// Installs the flagsChanged monitors. Idempotent.
    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleFlagsChanged(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        phaseTask = Task { [weak self] in
            guard let phases = self?.controller.phases() else { return }
            for await phase in phases {
                guard let self else { return }
                switch phase {
                case .idle:
                    self.hud.hide()
                case .unavailable:
                    self.hud.show()
                    // Keep the denial visible long enough to read, then retire.
                    try? await Task.sleep(for: .seconds(4))
                    self.controller.cancel()
                default:
                    self.hud.show()
                }
            }
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isDown = flags.contains(.function)
        let isBareFunction = isDown && flags.subtracting(.function).isEmpty
        let timestamp = ProcessInfo.processInfo.systemUptime

        if let trigger = machine.handle(isDown: isDown, isBareFunction: isBareFunction, timestamp: timestamp) {
            holdTask?.cancel()
            holdTask = nil
            handle(trigger)
            return
        }
        // A fresh bare-fn press arms the hold promotion timer.
        if isDown, isBareFunction, let startedAt = machine.activePressStartedAt {
            holdTask?.cancel()
            let threshold = startedAt + 0.8
            holdTask = Task { [weak self] in
                let nanoseconds = UInt64(max(threshold - ProcessInfo.processInfo.systemUptime, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if self.machine.beginHold() {
                    self.handle(.holdStart)
                }
            }
        }
        if !isDown {
            holdTask?.cancel()
            holdTask = nil
        }
    }

    private func handle(_ trigger: DictationTrigger) {
        guard Self.isEnabled else {
            machine.clearPendingDoubleTap()
            return
        }
        // While a shortcut recorder captures chords, fn presses must never
        // start a dictation session (same stand-down as the global hotkey).
        guard !KeyboardShortcutRecorderActivity.isAnyRecorderActive else { return }
        cmuxDebugLog("dictation.trigger \(trigger)")
        switch trigger {
        case .doubleTap:
            controller.toggle()
        case .holdStart:
            controller.beginHold()
        case .holdEnd:
            controller.endHold()
        }
    }
}
