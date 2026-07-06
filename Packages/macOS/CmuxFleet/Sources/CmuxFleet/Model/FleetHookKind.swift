/// Describes the workstream hook event kind Fleet consumes.
public enum FleetHookKind: String, Codable, Sendable {
    /// An agent session started.
    case sessionStart

    /// An agent turn stopped without necessarily ending the process.
    case stop

    /// The agent session ended.
    case sessionEnd

    /// The agent requested blocking human input.
    case blockingRequest

    /// The user submitted a prompt.
    case promptSubmit

    /// The agent used or reported a tool.
    case toolUse

    /// The agent emitted a notification.
    case notification

    /// Any hook not mapped to a Fleet-specific kind.
    case other
}
