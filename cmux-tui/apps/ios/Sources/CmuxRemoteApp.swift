import SwiftUI

@main
struct CmuxRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            SessionView()
        }
    }
}

@MainActor
@Observable
final class SessionModel {
    enum Phase: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    var invitation = ""
    var pathMode = RemoteClient.PathMode.auto
    var root = "~"
    var phase = Phase.disconnected
    var terminal: TerminalSnapshot?
    var connection: ConnectionSnapshot?

    private let client = RemoteClient()
    private var pump: Task<Void, Never>?
    private var grid: (cols: UInt16, rows: UInt16) = (80, 24)

    func connect() {
        guard phase != .connecting else { return }
        phase = .connecting
        let invitation = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathMode = pathMode
        let root = root
        let grid = grid
        let device = UIDevice.current.name

        Task {
            do {
                try await client.connect(
                    invitation: invitation, deviceName: device, pathMode: pathMode)
                try await client.openTerminal(root: root, cols: grid.cols, rows: grid.rows)
                phase = .connected
                startPump()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        pump?.cancel()
        pump = nil
        terminal = nil
        connection = nil
        phase = .disconnected
        Task { await client.disconnect() }
    }

    func send(_ text: String) {
        Task { try? await client.write(text) }
    }

    /// Match the remote PTY to what the phone can actually show. Called on
    /// rotation and whenever the keyboard changes the visible area.
    func resize(to grid: (cols: UInt16, rows: UInt16)) {
        guard grid != self.grid else { return }
        self.grid = grid
        guard phase == .connected else { return }
        Task {
            try? await client.resize(cols: grid.cols, rows: grid.rows)
            terminal = await client.terminal()
        }
    }

    /// Wait on output, then re-read the model. Blocking on the read rather than
    /// polling on a timer means an idle shell costs nothing and a busy one
    /// refreshes as fast as bytes arrive.
    private func startPump() {
        pump?.cancel()
        pump = Task { [client] in
            var lastSequence: UInt64 = .max
            while !Task.isCancelled {
                let produced = await client.readOutput() != nil
                if let snapshot = await client.terminal(),
                   produced || snapshot.throughSequence != lastSequence {
                    lastSequence = snapshot.throughSequence
                    terminal = snapshot
                }
                connection = await client.connection()
            }
        }
    }
}
