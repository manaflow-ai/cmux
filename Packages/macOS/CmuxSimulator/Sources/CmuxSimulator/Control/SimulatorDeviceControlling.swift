import Foundation

/// The device-lifecycle subset consumed by ``SimulatorWorkerClient``.
///
/// The protocol keeps worker supervision independently testable from the
/// installed Xcode and CoreSimulator state.
public protocol SimulatorDeviceControlling: Sendable {
    /// Returns the installed Simulator devices.
    func discoverDevices() async throws -> [SimulatorDevice]
    /// Boots a device. Booting an already booted device succeeds.
    func boot(deviceID: String) async throws
    /// Waits until SpringBoard reports that the device finished booting.
    func waitUntilBooted(deviceID: String) async throws
    /// Shuts down a device. Shutting down an already stopped device succeeds.
    func shutdown(deviceID: String) async throws
}
