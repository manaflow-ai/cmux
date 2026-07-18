/// The host-side operations required by the native Simulator pane UI.
public protocol SimulatorPaneClient: Sendable {
    /// Returns installed Simulator devices.
    func discoverDevices() async throws -> [SimulatorDevice]

    /// Boots, waits for, and attaches the worker to a device.
    /// - Parameters:
    ///   - id: The CoreSimulator device identifier.
    ///   - geometry: The measured pane geometry, when available.
    func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws

    /// Releases the worker and shuts down a CoreSimulator device.
    /// - Parameter id: The CoreSimulator device identifier.
    func shutdownDevice(id: String) async throws

    /// Subscribes to worker lifecycle, display, and inspection events.
    func subscribe() async -> SimulatorWorkerEventStream

    /// Sends one typed, ordered command to the isolated worker.
    /// - Parameter message: The command to enqueue.
    func send(_ message: SimulatorWorkerInbound) async

    /// Confirms that the host has opened the named frame transport, allowing
    /// older shared-memory names to be retired without racing host adoption.
    func acknowledgeFrameTransportAdoption(
        _ descriptor: SimulatorFrameTransportDescriptor
    ) async

    /// Establishes and confirms a known display orientation before input begins.
    func synchronizeOrientation(
        _ orientation: SimulatorOrientation
    ) async throws -> SimulatorDisplayMetadata?

    /// Performs one native Simulator tools action.
    /// - Parameter action: The typed action to perform.
    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult

    /// Invalidates only the transient worker generation, preserving this
    /// reusable client and the selected CoreSimulator device.
    func invalidateWorker() async

    /// Releases held input, asks the worker to exit, and tears down its pipes
    /// without shutting down the selected CoreSimulator device.
    func stop() async
}

public extension SimulatorPaneClient {
    func acknowledgeFrameTransportAdoption(
        _ descriptor: SimulatorFrameTransportDescriptor
    ) async {
        _ = descriptor
    }
}
