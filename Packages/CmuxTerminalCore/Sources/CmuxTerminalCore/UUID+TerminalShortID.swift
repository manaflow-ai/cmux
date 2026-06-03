public import Foundation

extension UUID {
    /// The first eight lowercase hex characters of the UUID, with dashes removed.
    ///
    /// Used to build compact, human-readable identifiers (e.g. placeholder tmux session names).
    public var terminalShortID: String {
        uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }
}
