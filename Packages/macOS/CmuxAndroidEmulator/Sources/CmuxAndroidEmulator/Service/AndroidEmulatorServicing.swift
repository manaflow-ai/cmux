/// Service boundary used by the Android emulator coordinator.
public protocol AndroidEmulatorServicing: Sendable {
    /// Reads installed AVDs and their current Android Debug Bridge state.
    func snapshot() async throws -> AndroidEmulatorSnapshot

    /// Restarts the user-installed Android Debug Bridge server.
    func restartADB() async throws

    /// Launches a validated AVD in the vendor emulator window.
    func launch(avdName: String) async throws

    /// Stops a running emulator after revalidating its AVD name and Android Debug Bridge transport.
    func stop(avdName: String, serial: String, transportID: String) async throws

    /// Sends one control action after revalidating the emulator's non-reusable transport identity.
    func perform(
        _ action: AndroidEmulatorControlAction,
        avdName: String,
        serial: String,
        transportID: String
    ) async throws

    /// Reads the primary display size after validating the selected transport.
    func displaySize(
        avdName: String,
        serial: String,
        transportID: String
    ) async throws -> AndroidEmulatorDisplaySize
}
