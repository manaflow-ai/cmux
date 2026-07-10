/// One Android Virtual Device available through the user's installed SDK.
public struct AndroidVirtualDevice: Identifiable, Sendable, Equatable {
    /// The AVD name, which is also its stable identity within an SDK home.
    public let name: String

    /// The current Android Debug Bridge state.
    public let state: AndroidVirtualDeviceState

    /// The stable SwiftUI identity for the device.
    public var id: String { name }

    /// Creates an Android Virtual Device snapshot.
    ///
    /// - Parameters:
    ///   - name: The AVD name reported by `emulator -list-avds`.
    ///   - state: The current Android Debug Bridge state.
    public init(name: String, state: AndroidVirtualDeviceState) {
        self.name = name
        self.state = state
    }
}
