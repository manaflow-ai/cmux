/// Service boundary used by the Android emulator coordinator.
public protocol AndroidEmulatorServicing: Sendable {
    /// Reads installed AVDs and their current Android Debug Bridge state.
    func snapshot() async throws -> AndroidEmulatorSnapshot

    /// Launches a validated AVD in the vendor emulator window.
    func launch(avdName: String) async throws

    /// Stops a running emulator after revalidating its AVD name and Android Debug Bridge transport.
    func stop(avdName: String, serial: String, transportID: String) async throws
}
