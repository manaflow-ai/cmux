/// An ICE candidate type (RFC 8445 section 5.1.1.1, `typ` in the line).
public enum CandidateType: String, Sendable, Hashable, CaseIterable {
    case host
    case srflx
    case prflx
    case relay

    /// Parses the `typ` token of a `candidate:` line; nil when absent.
    public init?(candidateLine: String) {
        let tokens = candidateLine.split(separator: " ")
        guard let index = tokens.firstIndex(of: "typ"), tokens.index(after: index) < tokens.endIndex,
              let type = CandidateType(rawValue: String(tokens[tokens.index(after: index)]))
        else { return nil }
        self = type
    }
}
