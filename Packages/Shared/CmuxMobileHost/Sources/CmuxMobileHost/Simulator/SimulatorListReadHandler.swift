import CmuxMobileWire

/// `read simulator.list`: the Mac's simulators, booted first.
public struct SimulatorListReadHandler: MobileReadHandler {
    let simulators: any SimulatorCaptureHost

    init(simulators: any SimulatorCaptureHost) {
        self.simulators = simulators
    }

    public func read(_ frame: ReadFrame, principal: MobileDevicePrincipal) async throws -> JSONValue {
        let list: [SimulatorInfo]
        do {
            list = try await simulators.simulators()
        } catch {
            throw MobileDaemonError(code: "simulator.unavailable", message: "simulators could not be listed", retryable: true)
        }
        let ordered = list.filter { $0.state == .booted } + list.filter { $0.state != .booted }
        return try JSONValue(encoding: SimulatorListResult(simulators: Array(ordered.prefix(128))))
    }
}
