import Darwin

/// Calls `body` with a NULL-terminated list of NUL-terminated copies of `strings`: the `argv` or `envp` that
/// `posix_spawn` and `exec` take. Chromium builds its argv the same way in one place
/// (base/process/launch_posix.cc, `LaunchProcess`: `std::vector<char*>` over the strings, NULL last).
///
/// The list and every copy are valid only while `body` runs; `body` must not keep a pointer out of it.
/// `posix_spawn` copies them into the child before it returns.
///
/// - Returns: What `body` returns, or nil when a copy could not be allocated (`body` does not run then).
package func withCStringList<Value>(_ strings: [String],
                                    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Value) -> Value? {
    // SAFETY: strdup makes a malloc'd NUL-terminated copy of each string, or returns NULL when out of memory; each
    // copy is freed exactly once, by the defer, after `body` returned.
    let copies: [UnsafeMutablePointer<CChar>?] = unsafe strings.map { unsafe strdup($0) }
    defer { unsafe copies.forEach { unsafe free($0) } }
    guard unsafe !copies.contains(where: { unsafe $0 == nil }) else { return nil }
    let list = unsafe copies + [nil]
    // SAFETY: the buffer is the list's own storage (the copies, then NULL), lent for the closure; `body` gets it
    // only for its call.
    return unsafe list.withUnsafeBufferPointer { buffer -> Value? in
        guard let first = unsafe buffer.baseAddress else { return nil }
        return unsafe body(first)
    }
}
