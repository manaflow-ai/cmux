import Foundation

/// Host-provided one-time teaser pointing at iPhone control of this pane.
///
/// The package renders it as a dismissable chip over a live device stage; the
/// HOST owns eligibility (feature flags, one-time persistence) and both
/// actions, so the package stays free of pairing and defaults policy. A `nil`
/// teaser renders nothing.
public struct SimulatorPhoneControlTeaser {
    /// Opens the host's phone-pairing flow (and retires the teaser).
    public let openPairing: @MainActor () -> Void
    /// Permanently dismisses the teaser without pairing.
    public let dismiss: @MainActor () -> Void

    public init(
        openPairing: @escaping @MainActor () -> Void,
        dismiss: @escaping @MainActor () -> Void
    ) {
        self.openPairing = openPairing
        self.dismiss = dismiss
    }
}
