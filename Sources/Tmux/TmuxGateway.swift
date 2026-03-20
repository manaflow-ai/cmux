import Foundation
import GhosttyKit

/// Bridges between the Ghostty C API action callback and the TmuxController.
///
/// The gateway manages:
/// - Parsing raw C actions into typed `TmuxEvent` values
/// - Write gating: buffering commands until the connection is ready
/// - Sending tmux protocol commands through the gateway surface's PTY
@MainActor
final class TmuxGateway {
    weak var controller: TmuxController?

    /// The terminal surface running the `tmux -CC` session.
    /// Commands are written to this surface's PTY to reach the tmux server.
    private(set) weak var gatewaySurface: TerminalSurface?

    /// Whether the gateway is ready to send commands.
    /// Set to true after the initial handshake completes and the Viewer
    /// begins emitting `.command` actions.
    private(set) var canWrite: Bool = false

    /// Commands buffered before `canWrite` becomes true.
    private var writeQueue: [String] = []

    // MARK: - Action Handling

    /// Parse a Ghostty C action and dispatch to the controller.
    func handleAction(_ action: ghostty_action_tmux_control_s, surface: TerminalSurface) {
        // First action should always be .enter — record the gateway surface
        if action.event == GHOSTTY_TMUX_ENTER {
            self.gatewaySurface = surface
        }

        guard let event = TmuxEvent.from(action) else {
            return
        }

        controller?.handleEvent(event)
    }

    // MARK: - Write Gating

    /// Enable command writing and flush any buffered commands.
    /// Called when the Viewer enters the idle/command state after initial sync.
    func enableWrite() {
        canWrite = true
        flushWriteQueue()
    }

    /// Send a tmux command through the gateway surface's PTY.
    /// If the gateway is not yet ready, the command is buffered.
    ///
    /// Commands must include a trailing newline.
    func sendCommand(_ command: String) {
        guard canWrite else {
            writeQueue.append(command)
            return
        }

        writeToGateway(command)
    }

    // MARK: - Private

    private func flushWriteQueue() {
        let pending = writeQueue
        writeQueue.removeAll()
        for command in pending {
            writeToGateway(command)
        }
    }

    private func writeToGateway(_ command: String) {
        guard let surface = gatewaySurface,
              let ghosttySurface = surface.surface else {
            return
        }

        // Send the command text to the gateway surface's PTY
        let data = command.data(using: .utf8) ?? Data()
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text(ghosttySurface, baseAddress, UInt(rawBuffer.count))
        }
    }

    /// Reset the gateway state. Called on disconnect.
    func reset() {
        canWrite = false
        writeQueue.removeAll()
        gatewaySurface = nil
        controller = nil
    }

    // MARK: - Global Dispatch

    /// Active gateways indexed by the gateway surface's panel ID.
    private static var activeGateways: [UUID: TmuxGateway] = [:]

    /// Entry point from the action handler. Routes the C action to the
    /// appropriate gateway/controller, creating them if this is an `enter` event.
    static func handleGlobalAction(
        _ action: ghostty_action_tmux_control_s,
        surface: TerminalSurface
    ) {
        let panelId = surface.id

        if action.event == GHOSTTY_TMUX_ENTER {
            // Create a new gateway and controller for this surface
            let gateway = TmuxGateway()
            let controller = TmuxController(
                gatewayPanelId: panelId,
                gateway: gateway
            )
            gateway.controller = controller
            controller.gatewaySurface = surface
            controller.tabManager = AppDelegate.shared?.tabManager
            activeGateways[panelId] = gateway
            gateway.handleAction(action, surface: surface)
            return
        }

        if action.event == GHOSTTY_TMUX_EXIT {
            if let gateway = activeGateways[panelId] {
                gateway.handleAction(action, surface: surface)
                activeGateways.removeValue(forKey: panelId)
            }
            return
        }

        // Route to existing gateway
        if let gateway = activeGateways[panelId] {
            gateway.handleAction(action, surface: surface)
        }
    }
}
