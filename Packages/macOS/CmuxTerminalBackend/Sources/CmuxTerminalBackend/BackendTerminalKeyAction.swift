/// One physical-key lifecycle action sent to the canonical terminal encoder.
public enum BackendTerminalKeyAction: String, Sendable {
    case press
    case release
    case `repeat`
}
