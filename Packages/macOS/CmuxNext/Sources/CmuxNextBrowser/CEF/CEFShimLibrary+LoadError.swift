/// How the shim's symbols resolve, why the shim did not load, and the ABI identity check
/// (``CEFShimLibrary/open(_:expected:)``, host mode's remote shim).
nonisolated extension CEFShimLibrary {
    enum LoadError: Error, Equatable {
        case open(String)
        case missingSymbol(String)
        /// Identities are SHA-256 hex strings of the header (`CEFShimABI`).
        case abiMismatch(expected: String, found: String)
    }

    /// Each function by symbol name: `dlsym` on the opened shim, or a test's stand-ins (`resolving`).
    struct Resolver {
        let symbol: (String) -> UnsafeMutableRawPointer?
        /// Host mode: the optional exports the Chromium Host's shim defines (its hello). Nil takes
        /// every optional export `symbol` finds.
        var hostExports: Set<String>?

        func callAsFunction<T>(_ name: String) throws(LoadError) -> T {
            guard let symbol = symbol(name) else { throw .missingSymbol(name) }
            return unsafeBitCast(symbol, to: T.self)
        }

        /// A function only newer shims export: nil when this one has none.
        func optional<T>(_ name: String) -> T? {
            guard hostExports?.contains(name) ?? true else { return nil }
            return symbol(name).map { unsafeBitCast($0, to: T.self) }
        }
    }

    /// Checks the shim's identity against the header this code was built with.
    static func checkABI(expected: String?, found: String?) throws(LoadError) {
        guard let expected, let found, expected == found else {
            throw .abiMismatch(expected: expected ?? "missing", found: found ?? "missing")
        }
    }
}
