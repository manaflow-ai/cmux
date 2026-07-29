import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileReconnectedToastGateTests {
    @Test func firstAttachStaysSilent() {
        var gate = MobileReconnectedToastGate()
        #expect(gate.shouldToast(from: .disconnected, to: .connected) == false)
    }

    @Test func genuineReconnectToasts() {
        var gate = MobileReconnectedToastGate()
        _ = gate.shouldToast(from: .disconnected, to: .connected)
        #expect(gate.shouldToast(from: .connected, to: .disconnected) == false)
        #expect(gate.shouldToast(from: .disconnected, to: .connected) == true)
    }

    @Test func viewRemountRefireDoesNotToast() {
        // SwiftUI re-fires `onChange(initial: true)` with previous == current
        // whenever the observing view remounts, e.g. returning from the
        // Notifications tab to the workspace list. A remount while connected
        // is not a reconnect.
        var gate = MobileReconnectedToastGate()
        _ = gate.shouldToast(from: .disconnected, to: .connected)
        #expect(gate.shouldToast(from: .connected, to: .connected) == false)
    }

    @Test func mountWhileConnectedPrimesButStaysSilent() {
        // A shell that mounts already connected must not toast, but must be
        // primed so the next genuine reconnect does.
        var gate = MobileReconnectedToastGate()
        #expect(gate.shouldToast(from: .connected, to: .connected) == false)
        #expect(gate.shouldToast(from: .connected, to: .disconnected) == false)
        #expect(gate.shouldToast(from: .disconnected, to: .connected) == true)
    }

    @Test func disconnectAloneNeverToasts() {
        var gate = MobileReconnectedToastGate()
        _ = gate.shouldToast(from: .disconnected, to: .connected)
        #expect(gate.shouldToast(from: .connected, to: .disconnected) == false)
        #expect(gate.shouldToast(from: .disconnected, to: .disconnected) == false)
    }
}
