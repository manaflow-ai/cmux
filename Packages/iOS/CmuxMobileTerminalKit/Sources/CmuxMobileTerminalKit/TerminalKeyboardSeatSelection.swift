/// Selects the keyboard seat authority a terminal host mounts with, and how
/// much of the keyboard notification stream that seat may trust.
///
/// `UIKeyboardLayoutGuide` is the default seat wherever it is trustworthy
/// (iOS ≤26): the dock rides UIKit's own keyboard transaction, pixel-locked
/// to the keyboard's private spring. On iOS 27 the guide can lie at the
/// screen bottom while the keyboard is visible (#9958), so those hosts seat
/// the dock from the `keyboardWillChangeFrame` constant instead, and trust
/// ONLY those will payloads: iOS 27 misreports keyboard frames outside the
/// will transaction, so a `keyboardDidChangeFrame` reseat or a steady-state
/// re-derivation moves a perfectly settled dock (#10518 recorded this when
/// it quarantined the rebuilt path away from iOS 27; #10006 shipped the
/// will-only contract that dogfood rated perfect). iOS ≤26 hosts routed to
/// the notification seat by the rebuild-revert kill switch keep the full
/// stream: their frames are trustworthy, and the did-frame reseat heals
/// mid-presentation keyboard retargets.
///
/// Hosts evaluate this once at mount, so any input change applies when the
/// workspace is reopened.
public struct TerminalKeyboardSeatSelection: Sendable, Equatable {
    /// The runtime OS major version (e.g. 26, 27).
    public let osMajorVersion: Int
    /// The remote kill switch routing iOS ≤26 to the notification seat.
    public let remoteRebuildRevert: Bool
    /// DEBUG-only force pinning the guide seat regardless of OS.
    public let debugForceLegacy: Bool
    /// DEBUG-only force routing iOS ≤26 to the notification seat.
    public let debugForceRebuild: Bool
    /// DEBUG-only force selecting the exact iOS 27 seat (notification
    /// authority, will-frames only) on any OS, so iOS ≤26 simulators can
    /// exercise the path iOS 27 devices ship with.
    public let debugForceIOS27Seat: Bool

    /// Creates a selection from the runtime inputs a host snapshots at mount.
    ///
    /// - Parameters:
    ///   - osMajorVersion: The runtime OS major version.
    ///   - remoteRebuildRevert: The remote kill switch value.
    ///   - debugForceLegacy: DEBUG-only guide-seat pin (UI-test env force).
    ///   - debugForceRebuild: DEBUG-only notification-seat pin (UI-test env
    ///     force or the Settings > Developer override).
    ///   - debugForceIOS27Seat: DEBUG-only iOS 27 seat pin (UI-test env
    ///     force).
    public init(
        osMajorVersion: Int,
        remoteRebuildRevert: Bool,
        debugForceLegacy: Bool = false,
        debugForceRebuild: Bool = false,
        debugForceIOS27Seat: Bool = false
    ) {
        self.osMajorVersion = osMajorVersion
        self.remoteRebuildRevert = remoteRebuildRevert
        self.debugForceLegacy = debugForceLegacy
        self.debugForceRebuild = debugForceRebuild
        self.debugForceIOS27Seat = debugForceIOS27Seat
    }

    /// Whether the host seats the dock on `UIKeyboardLayoutGuide`. False on
    /// iOS 27 (the guide lies there), under the remote kill switch or the
    /// DEBUG rebuild forces (both iOS ≤26 only), and under the iOS 27 seat
    /// force.
    public var usesKeyboardGuideSeat: Bool {
        if debugForceIOS27Seat { return false }
        if debugForceLegacy { return true }
        if osMajorVersion >= 27 { return false }
        if debugForceRebuild { return false }
        return !remoteRebuildRevert
    }

    /// Whether the notification seat trusts only `keyboardWillChangeFrame`
    /// payloads. True exactly where the OS misreports the rest of the
    /// stream: iOS 27+, and under the DEBUG iOS 27 seat force.
    public var seatTrustsOnlyWillFrames: Bool {
        if debugForceIOS27Seat { return true }
        if debugForceLegacy { return false }
        return osMajorVersion >= 27
    }
}
