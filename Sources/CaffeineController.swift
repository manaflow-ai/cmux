import Foundation
import Observation

/// Presents/dismisses the full-screen scene shown while the Mac is kept awake.
/// Implemented by `SleepyModeController`; injected so tests can observe the
/// transitions without AppKit windows.
@MainActor
protocol CaffeineLockScreenPresenting: AnyObject {
    var isPresented: Bool { get }
    func present()
    func dismiss()
}

/// Owns cmux's process-scoped idle-sleep activity.
///
/// The assertion keeps the Mac reachable while its display remains free to
/// sleep. It is intentionally not persisted: quitting cmux always releases it.
///
/// This is the single caffeinate action path: the CLI/socket `caffeine.*`
/// commands, the iOS Keep Awake RPC, the menu-bar toggle, and the Settings
/// toggle all mutate through `setEnabled`, which also drives the optional
/// lock screen (Sleepy Mode) while the Mac is kept awake.
@MainActor
@Observable
final class CaffeineController {
    typealias BeginActivity = () -> any NSObjectProtocol
    typealias EndActivity = (any NSObjectProtocol) -> Void

    private(set) var isEnabled = false

    @ObservationIgnored private let beginActivity: BeginActivity
    @ObservationIgnored private let endActivity: EndActivity
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored var onStateChange: ((Bool) -> Void)?

    /// The lock screen shown while caffeinated; nil when the composition root
    /// hasn't wired one (tests, early startup).
    @ObservationIgnored var lockScreenPresenter: (any CaffeineLockScreenPresenting)?
    /// Persisted "show the lock screen while keeping the Mac awake" preference,
    /// consulted when a caller doesn't pass an explicit per-call choice.
    @ObservationIgnored var lockScreenPreference: () -> Bool = { false }
    /// True while the currently visible lock screen was presented by this
    /// controller (as opposed to the user starting Sleepy Mode themselves).
    /// Only a caffeine-owned lock screen is dismissed when caffeine ends.
    @ObservationIgnored private var ownsLockScreen = false

    /// Persisted "engage the real macOS login lock while keeping the Mac
    /// awake" preference; the lock can only be lifted with Touch ID or the
    /// account password, which is why it is an action, never state we undo.
    @ObservationIgnored var lockMacPreference: () -> Bool = { false }
    /// Fires the real macOS login lock (Sleepy Mode's "Lock Mac" action).
    @ObservationIgnored var lockMacAction: () -> Void = {}

    var isLockScreenPresented: Bool { lockScreenPresenter?.isPresented ?? false }

    init(
        beginActivity: @escaping BeginActivity = {
            ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "cmux Keep Mac Awake"
            )
        },
        endActivity: @escaping EndActivity = { activity in
            ProcessInfo.processInfo.endActivity(activity)
        }
    ) {
        self.beginActivity = beginActivity
        self.endActivity = endActivity
    }

    /// `lockScreen` and `lockMac` are the per-call overrides (CLI
    /// `--lock-screen`/`--no-lock-screen`/`--lock-mac`, RPC `lock_screen`/
    /// `lock_mac`); nil falls back to the persisted preferences on the
    /// disabled→enabled transition and leaves both untouched on redundant
    /// enables. `lockMac` implies the cover unless the cover was explicitly
    /// declined.
    func setEnabled(_ enabled: Bool, lockScreen: Bool? = nil, lockMac: Bool? = nil) {
        let wasEnabled = isEnabled

        if enabled != wasEnabled {
            if enabled {
                activity = beginActivity()
            } else if let activity {
                endActivity(activity)
                self.activity = nil
            }
            isEnabled = enabled
        }

        applyLockScreen(enabled: enabled, wasEnabled: wasEnabled, override: lockScreen, lockMacOverride: lockMac)

        if enabled != wasEnabled {
            onStateChange?(enabled)
        }
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    /// Called when the lock screen goes away through its own exit path (any
    /// key/click, the palette toggle). Dropping ownership here keeps a Sleepy
    /// Mode session the user starts LATER from being torn down when caffeine
    /// ends.
    func noteLockScreenDismissed() {
        ownsLockScreen = false
    }

    private func applyLockScreen(enabled: Bool, wasEnabled: Bool, override: Bool?, lockMacOverride: Bool?) {
        guard enabled else {
            // Ending caffeine tears down only a lock screen caffeine put up; a
            // user-started Sleepy Mode session stays, and an engaged macOS
            // lock stays until the user unlocks it themselves.
            if let presenter = lockScreenPresenter, ownsLockScreen, presenter.isPresented {
                presenter.dismiss()
            }
            ownsLockScreen = false
            return
        }

        // Redundant enables without an explicit choice leave the lock screen
        // alone, so a user who dismissed it isn't surprised by it returning.
        let wantLockMac: Bool? = lockMacOverride ?? (wasEnabled ? nil : lockMacPreference())
        var wantCover: Bool? = override ?? (wasEnabled ? nil : lockScreenPreference())
        if wantLockMac == true, wantCover == nil {
            wantCover = true
        }

        if let presenter = lockScreenPresenter, let wantCover {
            if wantCover {
                if !presenter.isPresented {
                    presenter.present()
                    ownsLockScreen = true
                }
            } else if ownsLockScreen, presenter.isPresented {
                presenter.dismiss()
                ownsLockScreen = false
            }
        }

        if wantLockMac == true {
            lockMacAction()
        }
    }
}
