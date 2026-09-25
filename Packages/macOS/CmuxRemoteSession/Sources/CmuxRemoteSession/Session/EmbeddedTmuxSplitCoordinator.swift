public import Foundation
public import CmuxCore
public import CmuxFoundation
import Observation

/// Owns a split request for tmux rendered inside an ordinary remote terminal.
///
/// Mosh keeps carrying terminal input and output. This coordinator sends one
/// `split-window` through the existing SSH management configuration, targeting
/// the persisted session exactly. No local panel is created and an uncertain
/// command outcome is never retried automatically.
@MainActor
@Observable
public final class EmbeddedTmuxSplitCoordinator {
    /// Identity of the most recent request, retained for diagnostic correlation.
    public private(set) var requestID: UUID?
    /// Authoritative completion state of the most recent request.
    public private(set) var phase: EmbeddedTmuxSplitPhase = .idle
    /// The remote `%N` pane returned by tmux on success.
    public private(set) var paneID: String?

    @ObservationIgnored private let commands: any CommandRunning
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Creates a coordinator with an injected subprocess service.
    /// - Parameter commands: Runs the SSH management command and honors cancellation.
    public init(commands: any CommandRunning) {
        self.commands = commands
    }

    /// Starts exactly one remote split, rejecting concurrent requests.
    ///
    /// - Parameters:
    ///   - configuration: Current SSH configuration carrying a validated tmux profile.
    ///   - vertical: Whether tmux should stack the new pane vertically.
    ///   - insertBefore: Whether the new pane precedes the selected remote pane.
    ///   - focus: Whether tmux should select the new pane.
    /// - Returns: The accepted request ID, or `nil` for an invalid profile or a pending request.
    public func start(
        configuration: WorkspaceRemoteConfiguration,
        vertical: Bool,
        insertBefore: Bool,
        focus: Bool
    ) -> UUID? {
        guard phase != .running,
              configuration.transport == .ssh,
              let session = configuration.terminalProfile.tmuxSessionName else { return nil }
        var arguments = ["split-window", "-P", "-F", "#{pane_id}", vertical ? "-v" : "-h"]
        if insertBefore { arguments.append("-b") }
        if !focus { arguments.append("-d") }
        // '=' forbids prefix/pattern matching; ':' selects this session's current window.
        arguments += ["-t", "=\(session):"]
        let command = RemoteTmuxCommandBuilder(arguments: arguments).remoteShellCommand
        let sshArguments = configuration.batchSSHCommandArguments(
            command: command,
            effectiveSSHOptions: SSHAgentSocketResolver().moshManagementOptions(from: configuration.sshOptions)
        )
        let id = UUID()
        requestID = id
        paneID = nil
        phase = .running
        task = Task { [weak self, commands] in
            let result = await commands.run(
                directory: "/",
                executable: "/usr/bin/ssh",
                arguments: sshArguments,
                timeout: 15
            )
            guard !Task.isCancelled, let self, self.requestID == id else { return }
            self.task = nil
            let pane = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if result.executionError == nil, !result.timedOut, result.exitStatus == 0,
               pane.first == "%", !pane.dropFirst().isEmpty,
               pane.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) {
                self.paneID = pane
                self.phase = .succeeded
            } else {
                self.phase = .failed
            }
        }
        return id
    }

    /// Cancels work when the workspace disconnects, reconnects, or is retired.
    /// Late completions from a prior connection cannot update the new lifetime.
    public func reset() {
        requestID = nil
        task?.cancel()
        task = nil
        paneID = nil
        phase = .idle
    }

    /// Waits for an accepted request without submitting or retrying another command.
    /// - Parameter id: The receipt returned by ``start(configuration:vertical:insertBefore:focus:)``.
    /// - Returns: Its terminal phase, or `nil` if the connection lifetime was reset or replaced.
    public func completion(for id: UUID) async -> EmbeddedTmuxSplitPhase? {
        guard requestID == id else { return nil }
        await task?.value
        return requestID == id ? phase : nil
    }
}
