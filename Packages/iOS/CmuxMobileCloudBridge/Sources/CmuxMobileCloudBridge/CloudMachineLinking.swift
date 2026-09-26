public import CmuxMobileCloud
public import Foundation

/// The input side of one attached terminal, as the bridge uses it.
public protocol CloudTerminalLinking: Sendable {
    /// Queues input bytes for the attached terminal.
    func send(_ bytes: Data)
    /// Reports the phone's grid to the daemon.
    func resize(cols: Int, rows: Int)
    /// Stops streaming output, leaving the link open for the catalog.
    func detach()
}

/// One machine's daemon link, as the bridge uses it.
public protocol CloudMachineLinking: Sendable {
    /// Reads the daemon's workspaces and terminals in one pass.
    func loadCatalog() async throws -> (
        workspaces: [CloudWorkspaceSummary],
        terminals: [CloudTerminalSummary]
    )
    /// Streams one terminal's output into `output` until the link is detached.
    func attach(
        terminalID: String,
        output: @escaping @Sendable (CloudTerminalOutputEvent) -> Void
    ) async throws -> any CloudTerminalLinking
}

/// Supplies a link per machine, once the tunnel is up.
///
/// The bridge depends on this rather than on ``CloudSessionController`` so its
/// attachment behavior — ordered delivery, input held while a link comes up,
/// and repaint requests that do not restart an attach already running — is
/// testable without a tunnel, a daemon or a VM.
@MainActor
public protocol CloudMachineLinkProviding {
    /// The link for `machine`, or `nil` while the tunnel is not ready.
    func link(for machine: CloudMachine) -> (any CloudMachineLinking)?
}

extension CloudTerminalAttachment: CloudTerminalLinking {}

extension CloudMachineConnection: CloudMachineLinking {
    public func attach(
        terminalID: String,
        output: @escaping @Sendable (CloudTerminalOutputEvent) -> Void
    ) async throws -> any CloudTerminalLinking {
        try await attach(terminalID: terminalID, output: output) as CloudTerminalAttachment
    }
}

extension CloudSessionController: CloudMachineLinkProviding {
    public func link(for machine: CloudMachine) -> (any CloudMachineLinking)? {
        connection(for: machine)
    }
}
