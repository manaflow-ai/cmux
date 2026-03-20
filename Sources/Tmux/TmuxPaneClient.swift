import Foundation
import GhosttyKit

/// Manages a single tmux pane's virtual surface.
///
/// Each TmuxPaneClient creates a Manual I/O TerminalSurface that renders
/// terminal output without a local PTY. Keystrokes captured by the
/// `io_write_cb` are forwarded to the tmux server via the controller.
@MainActor
final class TmuxPaneClient {
    let tmuxPaneId: Int
    let tmuxWindowId: Int
    let surface: TerminalSurface
    weak var controller: TmuxController?

    /// Self-reference retained for the C callback context.
    /// Released in `teardown()`.
    private var retainedSelf: Unmanaged<TmuxPaneClient>?

    init(
        tmuxPaneId: Int,
        tmuxWindowId: Int,
        tabId: UUID,
        controller: TmuxController
    ) {
        self.tmuxPaneId = tmuxPaneId
        self.tmuxWindowId = tmuxWindowId
        self.controller = controller

        // Create the virtual surface with Manual I/O mode
        let surface = TerminalSurface(
            tabId: tabId,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil
        )
        self.surface = surface

        // Retain self for the C callback and configure Manual I/O
        let retained = Unmanaged.passRetained(self)
        self.retainedSelf = retained
        surface.manualIOConfig = TerminalSurface.ManualIOConfig(
            writeCallback: Self.ioWriteCallback,
            userdata: retained.toOpaque()
        )
    }

    // MARK: - Output

    /// Feed output data from the tmux server to the virtual surface.
    func feedOutput(_ data: Data) {
        guard let ghosttySurface = surface.surface else { return }

        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_process_output(ghosttySurface, baseAddress, UInt(rawBuffer.count))
        }
    }

    // MARK: - Input Callback

    /// C callback invoked when the virtual surface produces output (keystrokes).
    /// Forwards the data to the tmux server via the controller.
    private static let ioWriteCallback: ghostty_io_write_cb = { userdata, data, len in
        guard let userdata, let data, len > 0 else { return }

        let client = Unmanaged<TmuxPaneClient>.fromOpaque(userdata).takeUnretainedValue()
        let keyData = Data(bytes: data, count: Int(len))

        // Dispatch to main actor since controller is @MainActor
        DispatchQueue.main.async {
            client.controller?.sendKeys(keyData, toPane: client.tmuxPaneId)
        }
    }

    // MARK: - Lifecycle

    /// Clean up the pane client, releasing the retained self reference.
    func teardown() {
        retainedSelf?.release()
        retainedSelf = nil
        if let ghosttySurface = surface.surface {
            ghostty_surface_free(ghosttySurface)
        }
    }
}
