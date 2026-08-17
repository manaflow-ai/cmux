/// Identity provenance retained by one restorable-agent index entry.
///
/// Heuristic process scans remain useful for restore tooling, but only a hook
/// token or exact process binding may establish deterministic sidebar presence.
struct RestorableAgentSessionEntryProvenance: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let hookRecord = Self(rawValue: 1 << 0)
    static let exactProcessBinding = Self(rawValue: 1 << 1)
    static let heuristicProcessDetection = Self(rawValue: 1 << 2)
}
