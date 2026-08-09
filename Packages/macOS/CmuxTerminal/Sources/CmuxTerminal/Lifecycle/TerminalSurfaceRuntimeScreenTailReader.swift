/// Serializes bounded screen-tail formatting across the terminal runtime.
///
/// Callers acquire a native-access borrow before their first suspension. The
/// reader owns admission after that suspension so remote disconnects cannot
/// fan out one blocking Ghostty formatter per surface. Cancelled queued reads
/// release their borrow without entering the native runtime.
actor TerminalSurfaceRuntimeScreenTailReader {
    func read(
        _ request: TerminalSurfaceRuntimeScreenTailRequest,
        borrow: TerminalSurfaceRuntimeNativeAccessBorrow
    ) -> String? {
        defer { borrow.release() }
        guard !Task.isCancelled else { return nil }
        return request.read()
    }
}
