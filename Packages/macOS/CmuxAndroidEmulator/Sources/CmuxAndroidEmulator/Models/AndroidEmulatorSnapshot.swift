public import Foundation

/// Current Android SDK and AVD state displayed by cmux.
public struct AndroidEmulatorSnapshot: Sendable, Equatable {
    /// The selected Android SDK root.
    public let sdkRootURL: URL

    /// AVDs sorted by localized name.
    public let devices: [AndroidVirtualDevice]

    /// A non-fatal Android Debug Bridge limitation, when present.
    public let warning: AndroidEmulatorWarning?

    /// Creates an Android emulator snapshot.
    ///
    /// - Parameters:
    ///   - sdkRootURL: The selected Android SDK root.
    ///   - devices: The installed AVDs.
    ///   - warning: A non-fatal Android Debug Bridge limitation.
    public init(
        sdkRootURL: URL,
        devices: [AndroidVirtualDevice],
        warning: AndroidEmulatorWarning?
    ) {
        self.sdkRootURL = sdkRootURL
        self.devices = devices
        self.warning = warning
    }
}
