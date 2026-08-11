/// A terminal's lifecycle state for sidebar command dispatch.
@_spi(CmuxHostTransport)
public enum CMUXSidebarRunCommandTerminalState: Equatable, Sendable {
    /// The terminal has a live surface that can accept input.
    case live
    /// The terminal is hibernated and must not be woken by dispatch.
    case hibernated
    /// The terminal does not currently have a live surface.
    case cold
    /// The terminal surface's process has exited.
    case dead
}

/// The resolved kind of target for a sidebar command.
@_spi(CmuxHostTransport)
public enum CMUXSidebarRunCommandTargetKind: Equatable, Sendable {
    /// A terminal target with its current lifecycle state.
    case terminal(CMUXSidebarRunCommandTerminalState)
    /// No target exists at the requested workspace and surface identifiers.
    case missing
    /// The requested target exists but is not a terminal.
    case nonterminal
}

/// A structured reason that a sidebar command was rejected.
@_spi(CmuxHostTransport)
public enum CMUXSidebarRunCommandRejection: Equatable, Sendable {
    /// The command violates the accepted input contract.
    case commandRejected
    /// No target exists at the requested identifiers.
    case terminalNotFound
    /// The requested target is not a terminal.
    case targetNotTerminal
    /// The terminal is not live and dispatch must not wake it.
    case terminalUnavailable
    /// The terminal rejected either the text or Enter input event.
    case terminalInputRejected
}

/// The result of attempting to dispatch a sidebar command.
@_spi(CmuxHostTransport)
public enum CMUXSidebarRunCommandDispatchResult: Equatable, Sendable {
    /// The terminal accepted the command text followed by Enter.
    case accepted
    /// Dispatch was rejected for the associated structured reason.
    case rejected(CMUXSidebarRunCommandRejection)
}

/// Validates and synchronously sends sidebar commands to an already-live terminal.
@_spi(CmuxHostTransport)
public struct CMUXSidebarRunCommandDispatcher: Sendable {
    /// The maximum accepted command length measured in UTF-8 bytes.
    public let maximumCommandUTF8Bytes = 8_192

    /// Creates a command dispatcher with the fixed host input limit.
    public init() {}

    /// Validates the command and target before sending exact text followed by Enter.
    ///
    /// The callbacks are nonescaping and execute synchronously on the caller's executor.
    public func dispatch(
        command: String,
        targetKind: CMUXSidebarRunCommandTargetKind,
        sendText: (String) -> Bool,
        sendEnter: () -> Bool
    ) -> CMUXSidebarRunCommandDispatchResult {
        guard !command.isEmpty,
              command.utf8.count <= maximumCommandUTF8Bytes,
              !command.unicodeScalars.contains(where: { scalar in
                  let value = scalar.value
                  return value <= 0x1F
                      || (0x7F...0x9F).contains(value)
                      || value == 0x2028
                      || value == 0x2029
              }) else {
            return .rejected(.commandRejected)
        }

        switch targetKind {
        case .missing:
            return .rejected(.terminalNotFound)
        case .nonterminal:
            return .rejected(.targetNotTerminal)
        case .terminal(.live):
            break
        case .terminal(.hibernated), .terminal(.cold), .terminal(.dead):
            return .rejected(.terminalUnavailable)
        }

        guard sendText(command), sendEnter() else {
            return .rejected(.terminalInputRejected)
        }
        return .accepted
    }
}
