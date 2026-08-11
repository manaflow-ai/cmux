/// Serializes bounded screen-tail formatting across the terminal runtime.
///
/// Requests may wait here without borrowing their surface, so one blocked
/// formatter cannot defer another surface's process teardown. After admission,
/// the reader atomically acquires that runtime generation before dereferencing
/// its pointer. Cancelled or already-closing requests never enter Ghostty.
actor TerminalSurfaceRuntimeScreenTailReader {
    func read(_ request: TerminalSurfaceRuntimeScreenTailRequest) -> String? {
        guard !Task.isCancelled,
              let borrow = request.nativeAccessGate.acquireBorrow() else {
            return nil
        }
        defer { borrow.release() }
        return request.read()
    }
}
