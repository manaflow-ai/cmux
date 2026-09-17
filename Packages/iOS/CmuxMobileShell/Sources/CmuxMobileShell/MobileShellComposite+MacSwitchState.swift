import Foundation

extension MobileShellComposite {
    /// Whether any foreground Mac switch attempt is currently in flight.
    ///
    /// `switchToMac` returns `false` both for a genuine connection failure and
    /// for an attempt superseded by a newer switch (which leaves the newer
    /// attempt's id in place; `finishMacSwitchAttempt` only clears a matching
    /// id). Reconnect UIs read this at result time to avoid showing a
    /// "couldn't connect" alert for an attempt that merely lost the race to a
    /// switch the user started elsewhere.
    ///
    /// Lives in an extension file (with `macSwitchAttemptID` made internal)
    /// instead of `MobileShellComposite.swift` to respect that file's length
    /// budget.
    public var isMacSwitchInFlight: Bool { macSwitchAttemptID != nil }
}
