/// Why the shim did not load, and the ABI identity check (``CEFShimLibrary/open(_:expected:)``, host mode's
/// remote shim).
nonisolated extension CEFShimLibrary {
    enum LoadError: Error, Equatable {
        case open(String)
        case missingSymbol(String)
        /// Identities are SHA-256 hex strings of the header (`CEFShimABI`).
        case abiMismatch(expected: String, found: String)
    }

    /// Checks the shim's identity against the header this code was built with.
    static func checkABI(expected: String?, found: String?) throws(LoadError) {
        guard let expected, let found, expected == found else {
            throw .abiMismatch(expected: expected ?? "missing", found: found ?? "missing")
        }
    }
}
