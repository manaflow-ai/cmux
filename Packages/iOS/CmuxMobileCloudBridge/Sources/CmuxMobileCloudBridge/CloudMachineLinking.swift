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
    /// Creates a workspace with one starter terminal and returns its id, or
    /// nil when the daemon refused.
    func createWorkspace(name: String?) async -> String?
    /// Creates a terminal inside `workspaceID` and returns its id, or nil
    /// when the daemon refused.
    func createTerminal(inWorkspace workspaceID: String, name: String?) async -> String?
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
    /// Drops `machine`'s link so the next ``link(for:)`` dials it afresh.
    func resetLink(for machine: CloudMachine)
}

/// Where the user's choice to hide a Cloud machine is persisted.
@MainActor
public protocol CloudMachineVisibilityStoring: AnyObject {
    /// Machine ids hidden on this phone.
    var hiddenMachineIDs: Set<String> { get }
    /// Records whether one machine is hidden.
    func setMachine(id: String, hidden: Bool)
}

extension CloudSessionController: CloudMachineVisibilityStoring {}

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
    public func resetLink(for machine: CloudMachine) {
        retryConnection(for: machine.id)
    }

    public func link(for machine: CloudMachine) -> (any CloudMachineLinking)? {
        connection(for: machine)
    }
}
