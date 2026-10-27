import Darwin

/// The `switches` argument of `cmux_shim_initialize`: NUL-terminated copies of each switch and the
/// NULL that ends the list, owned as long as the runtime keeps this (it keeps the argv Chromium
/// started with for its life), and freed once when it goes.
@safe
nonisolated final class CEFSwitchArguments {
    private let copies: [UnsafeMutablePointer<CChar>?]
    /// The NULL-terminated argv; each entry stays valid while this lives.
    let argv: [UnsafePointer<CChar>?]

    init(_ switches: [String]) {
        // SAFETY: strdup copies each switch, NUL-terminated (NULL when out of memory, which ends the list
        // early in C); deinit frees each copy once.
        let copies: [UnsafeMutablePointer<CChar>?] = unsafe switches.map { unsafe strdup($0) }
        unsafe self.copies = copies
        // SAFETY: read-only views of the copies above, which live as long as `self`.
        unsafe argv = copies.map { unsafe UnsafePointer($0) } + [nil]
    }

    deinit {
        // SAFETY: each copy came from strdup in init and nothing reads it after this object goes.
        unsafe copies.forEach { unsafe free($0) }
    }
}
