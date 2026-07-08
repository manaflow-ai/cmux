public import Foundation
import Observation

/// Device-local dismissal state for the iOS alternate-screen terminal notice.
@MainActor
@Observable
public final class AltScreenNoticeState {
    static let dismissedDefaultsKey = "mobile.altScreenNotice.dismissed"

    @ObservationIgnored private let defaults: UserDefaults

    /// Whether the user permanently hid the alternate-screen sizing notice.
    public private(set) var dismissed: Bool

    /// Creates alternate-screen notice state backed by injected defaults.
    ///
    /// - Parameter defaults: The defaults store used to persist the global dismissal flag.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.dismissed = defaults.bool(forKey: Self.dismissedDefaultsKey)
    }

    /// Permanently hides the alternate-screen sizing notice.
    public func dismiss() {
        dismissed = true
        defaults.set(true, forKey: Self.dismissedDefaultsKey)
    }
}
