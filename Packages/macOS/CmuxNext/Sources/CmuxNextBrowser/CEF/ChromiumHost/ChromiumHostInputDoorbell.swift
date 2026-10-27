#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextSharedRegionC
import Darwin

/// What wakes the host's parked reader; a seam so tests use their own port.
nonisolated protocol ChromiumHostInputDoorbell: Sendable {
    /// Sends one wake without waiting: false when the reader's port is dead.
    func ring() -> Bool
}

/// The host's doorbell: a send right to the Mach port it checked in.
nonisolated final class ChromiumHostMachDoorbell: ChromiumHostInputDoorbell {
    let port: mach_port_t

    /// Takes the send right `port`; released when this goes.
    init(port: mach_port_t) { self.port = port }

    deinit { cmux_input_ring_doorbell_release(port) }

    /// The doorbell the host checked in under `name`, or nil when it has
    /// none. One synchronous message to launchd: never on the main thread.
    static func lookUp(name: String) -> ChromiumHostMachDoorbell? {
        // SAFETY: the lookup reads the NUL-terminated copy of `name` Swift makes for the call.
        let port = unsafe cmux_input_ring_doorbell_look_up(name)
        return port == 0 ? nil : ChromiumHostMachDoorbell(port: port)
    }

    func ring() -> Bool { cmux_input_ring_doorbell_ring(port) != 0 }
}
#endif
