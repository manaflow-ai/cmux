/// Why a pane-content query could not be compiled.
public enum PaneContentMatcherError: Error, Equatable, Sendable {
    /// The regular expression did not parse; the payload is the system's explanation.
    case invalidRegex(String)
}
