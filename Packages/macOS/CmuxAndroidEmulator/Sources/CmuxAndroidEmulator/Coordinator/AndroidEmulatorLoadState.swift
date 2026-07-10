/// Loading state projected by ``AndroidEmulatorCoordinator`` for SwiftUI.
public enum AndroidEmulatorLoadState: Sendable, Equatable {
    /// No discovery has started yet.
    case idle

    /// SDK and AVD discovery is in progress.
    case loading

    /// SDK and AVD discovery succeeded.
    case loaded(AndroidEmulatorSnapshot)

    /// SDK discovery or an essential vendor command failed.
    case failed(AndroidEmulatorError)
}
