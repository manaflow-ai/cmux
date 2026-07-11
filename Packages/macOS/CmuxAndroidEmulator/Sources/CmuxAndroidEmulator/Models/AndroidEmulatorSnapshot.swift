public import Foundation

/// Current Android SDK and AVD state displayed by cmux.
public struct AndroidEmulatorSnapshot: Sendable, Equatable {
    /// The selected Android SDK root.
    public let sdkRootURL: URL

    /// AVDs sorted by localized name.
    public let devices: [AndroidVirtualDevice]

    /// A non-fatal Android Debug Bridge limitation, when present.
    public let warning: AndroidEmulatorWarning?

    /// Connected emulator serials when Android Debug Bridge returned an authoritative device list.
    public let connectedEmulatorSerials: Set<String>?

    /// Creates an Android emulator snapshot.
    ///
    /// - Parameters:
    ///   - sdkRootURL: The selected Android SDK root.
    ///   - devices: The installed AVDs.
    ///   - warning: A non-fatal Android Debug Bridge limitation.
    ///   - connectedEmulatorSerials: Authoritative connected serials, or `nil` when adb could not list them.
    public init(
        sdkRootURL: URL,
        devices: [AndroidVirtualDevice],
        warning: AndroidEmulatorWarning?,
        connectedEmulatorSerials: Set<String>? = nil
    ) {
        self.sdkRootURL = sdkRootURL
        self.devices = devices
        self.warning = warning
        self.connectedEmulatorSerials = connectedEmulatorSerials
    }
}
