/// The complete supported Simulator control surface consumed by a pane client.
public protocol SimulatorControlling: SimulatorDeviceControlling {
    /// Performs one typed device, app, media, permission, or capture action.
    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult
}
