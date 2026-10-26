import Foundation

nonisolated extension CEFShimLibrary {
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

    /// The functions `symbol` gives by name, with no shim loaded (a test's spy shim).
    static func resolving(_ symbol: @escaping (String) -> UnsafeMutableRawPointer?) throws(LoadError) -> CEFShimLibrary {
        try CEFShimLibrary(Resolver(symbol: symbol))
    }

    /// Host mode's functions (``CEFRemoteShim``): every required export from `symbol`, an optional
    /// one only when the host's shim defines it (`hostExports`, from the host's hello). The remote
    /// shim exports all of them, so without this `CEFForkFeatures` would see the remote dylib and
    /// not the host's fork.
    static func resolving(_ symbol: @escaping (String) -> UnsafeMutableRawPointer?,
                          hostExports: Set<String>) throws(LoadError) -> CEFShimLibrary {
        try CEFShimLibrary(Resolver(symbol: symbol, hostExports: hostExports))
    }

    /// The same functions, `replacement`'s where it has one (``CEFMirrorCache``'s mirror reads).
    func overriding(_ replacement: @escaping (String) -> UnsafeMutableRawPointer?) throws(LoadError) -> CEFShimLibrary {
        let base = self.resolver
        return try CEFShimLibrary(Resolver(symbol: { replacement($0) ?? base.symbol($0) }, hostExports: base.hostExports))
    }
}
