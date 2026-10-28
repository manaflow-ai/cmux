import Foundation

nonisolated extension CEFShimLibrary {
    /// Each function by symbol name: `dlsym` on the opened shim, or a test's stand-ins (`resolving`).
    @safe
    struct Resolver {
        let symbol: (String) -> UnsafeMutableRawPointer?
        /// Host mode: the optional exports the Chromium Host's shim defines (its hello). Nil takes
        /// every optional export `symbol` finds.
        var hostExports: Set<String>?

        // SAFETY (both lookups): `symbol` answers the export `name` of a shim that stays mapped (a handle
        // never closed), or a test's stand-in; `T` is the export's C function type in cmux_cef_shim.h,
        // and the shim's ABI identity is checked against that header before any call (`open`, `make`).
        func callAsFunction<T>(_ name: String) throws(LoadError) -> T {
            guard let address = unsafe symbol(name) else { throw .missingSymbol(name) }
            return unsafe unsafeBitCast(address, to: T.self)
        }

        /// A function only newer shims export: nil when this one has none.
        func optional<T>(_ name: String) -> T? {
            guard hostExports?.contains(name) ?? true else { return nil }
            return unsafe symbol(name).map { unsafe unsafeBitCast($0, to: T.self) }
        }

        /// A function only newer shims export that passes this process's Mach ports: nil in host
        /// mode, where a port name would reach the Chromium Host's process as a bare number.
        func inProcess<T>(_ name: String) -> T? {
            hostExports == nil ? optional(name) : nil
        }
    }

    /// The functions `symbol` gives by name, with no shim loaded (a test's spy shim).
    static func resolving(_ symbol: @escaping (String) -> UnsafeMutableRawPointer?) throws(LoadError) -> CEFShimLibrary {
        try unsafe CEFShimLibrary(Resolver(symbol: symbol))
    }

    /// Host mode's functions (``CEFRemoteShim``): every required export from `symbol`, an optional
    /// one only when the host's shim defines it (`hostExports`, from the host's hello). The remote
    /// shim exports all of them, so without this `CEFForkFeatures` would see the remote dylib and
    /// not the host's fork.
    static func resolving(_ symbol: @escaping (String) -> UnsafeMutableRawPointer?,
                          hostExports: Set<String>) throws(LoadError) -> CEFShimLibrary {
        try unsafe CEFShimLibrary(Resolver(symbol: symbol, hostExports: hostExports))
    }

    /// The same functions, `replacement`'s where it has one (``CEFMirrorCache``'s mirror reads).
    func overriding(_ replacement: @escaping (String) -> UnsafeMutableRawPointer?) throws(LoadError) -> CEFShimLibrary {
        let base = self.resolver
        // SAFETY: each name resolves to `replacement`'s function of the export's C type, else to the base shim's.
        return try unsafe CEFShimLibrary(Resolver(symbol: { unsafe replacement($0) ?? base.symbol($0) }, hostExports: base.hostExports))
    }
}
