public import Foundation
import Observation

/// A one-time in-app guidance tip shown at a moment of intent, continuing
/// onboarding into real app use. Raw values are versioned so reworked copy or
/// placement can re-show a tip by bumping its suffix.
public enum MobileGuidanceTip: String, CaseIterable, Sendable {
    /// Offered in the notification feed while push is off (the onboarding push
    /// step was skipped or declined).
    case enablePushAlerts = "enablePushAlerts.v1"

    /// Shown on the first connected workspace list visit.
    case openFirstWorkspace = "openFirstWorkspace.v1"
}

/// Persists which guidance tips were dismissed, so each shows at most once.
///
/// The backing `UserDefaults` is injected so the store is testable without
/// touching `.standard`; the app constructs it at the composition root.
@MainActor
@Observable
public final class MobileGuidanceStore {
    /// The defaults key holding the dismissed tip raw values.
    public static let dismissedKey = "dev.cmux.mobile.guidance.dismissed.v1"

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Raw values of every dismissed tip.
    public private(set) var dismissedTipIDs: Set<String>

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.dismissedKey) ?? []
        self.dismissedTipIDs = Set(stored)
    }

    /// Whether the tip was already dismissed (shown and acknowledged).
    public func isDismissed(_ tip: MobileGuidanceTip) -> Bool {
        dismissedTipIDs.contains(tip.rawValue)
    }

    /// Dismiss the tip durably; it never shows again until ``reset()``.
    public func dismiss(_ tip: MobileGuidanceTip) {
        guard !dismissedTipIDs.contains(tip.rawValue) else { return }
        dismissedTipIDs.insert(tip.rawValue)
        persist()
    }

    /// Forget every dismissal so all tips can show again (Settings replay).
    public func reset() {
        guard !dismissedTipIDs.isEmpty else { return }
        dismissedTipIDs = []
        persist()
    }

    private func persist() {
        defaults.set(dismissedTipIDs.sorted(), forKey: Self.dismissedKey)
    }
}
