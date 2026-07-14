internal import Foundation

/// One pane's lifecycle session against one explicit simulator device.
///
/// The session applies ``SimulatorLifecyclePolicy`` with real effects: it
/// re-reads the device's state at open time, boots or attaches accordingly,
/// and on close shuts the device down only when this session booted it.
/// Every `simctl` invocation addresses the session's ``udid`` — never the
/// `"booted"` alias, and never any device this session did not boot.
///
/// ```swift
/// let session = SimulatorDeviceSession(udid: udid, runner: SimctlCommandRunner())
/// let ownership = try await session.open()
/// // … stream the display …
/// try await session.close() // shuts down only if ownership == .bootedByCmux
/// ```
public actor SimulatorDeviceSession {
    /// The one device this session may operate on.
    public let udid: SimulatorDeviceUDID
    private let runner: any SimctlCommandRunning
    private let policy: SimulatorLifecyclePolicy
    private var ownership: SimulatorSessionOwnership?

    /// Creates a session for one device.
    ///
    /// - Parameters:
    ///   - udid: The device to operate on.
    ///   - runner: The `simctl` seam.
    ///   - policy: The lifecycle decision rules. Defaults to the standard policy.
    public init(
        udid: SimulatorDeviceUDID,
        runner: any SimctlCommandRunning,
        policy: SimulatorLifecyclePolicy = SimulatorLifecyclePolicy()
    ) {
        self.udid = udid
        self.runner = runner
        self.policy = policy
    }

    /// Opens the session: attaches to the device if it is already booted,
    /// boots it if it is shut down, and refuses anything mid-transition.
    ///
    /// - Returns: Who owns the device's shutdown after this call.
    /// - Throws: ``SimulatorSessionError`` when the device is missing or not
    ///   openable, or the underlying `simctl` failure.
    @discardableResult
    public func open() async throws -> SimulatorSessionOwnership {
        let listOutput = try await runner.run(["list", "devices", "--json"])
        let catalog = try SimulatorDeviceCatalog(simctlListJSON: listOutput)
        guard let device = catalog.device(withUDID: udid) else {
            throw SimulatorSessionError.deviceNotFound(udid)
        }
        switch policy.openAction(for: device) {
        case .attach:
            ownership = .attachedToRunningDevice
        case .boot:
            do {
                try await runner.run(["boot", udid.rawValue])
                ownership = .bootedByCmux
            } catch let failure as SimctlCommandFailure {
                // Lost a boot race: someone else booted the device between the
                // list and the boot. Re-check and attach instead of owning a
                // boot that was not ours.
                let refreshed = try await runner.run(["list", "devices", "--json"])
                let refreshedCatalog = try SimulatorDeviceCatalog(simctlListJSON: refreshed)
                guard refreshedCatalog.device(withUDID: udid)?.state == .booted else {
                    throw failure
                }
                ownership = .attachedToRunningDevice
            }
            if ownership == .bootedByCmux {
                // bootstatus blocks until boot completes — a real completion
                // signal from CoreSimulator, not a poll on our side.
                try await runner.run(["bootstatus", udid.rawValue])
            }
        case .refuse(let reason):
            throw SimulatorSessionError.deviceNotOpenable(reason)
        }
        guard let ownership else {
            throw SimulatorSessionError.deviceNotOpenable(.transitioning(device.state))
        }
        return ownership
    }

    /// Closes the session, shutting the device down only when this session
    /// booted it. Attach-only sessions leave the device untouched.
    ///
    /// - Throws: The underlying `simctl` failure when the shutdown fails.
    public func close() async throws {
        guard let ownership, policy.shouldShutdownOnClose(ownership: ownership) else {
            self.ownership = nil
            return
        }
        self.ownership = nil
        try await runner.run(["shutdown", udid.rawValue])
    }

    /// Who owns the device's shutdown, when the session is open.
    public var currentOwnership: SimulatorSessionOwnership? {
        ownership
    }
}
