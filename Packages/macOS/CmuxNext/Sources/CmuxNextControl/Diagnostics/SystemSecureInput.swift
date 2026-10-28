import Carbon.HIToolbox

/// Secure keyboard entry as the window server reports it (`IsSecureEventInputEnabled`): any app's password
/// field, or a terminal's secure input (TerminalSecureInput). `trace.start` reads it (the task 128 gate), so no
/// per-key trace record is written while one is on.
public struct SystemSecureInput: TraceSecureInput {
    public init() {}

    public var isSecureInputActive: Bool { IsSecureEventInputEnabled() }
}
