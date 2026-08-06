// Safety: the request's borrowed native pointer is read only by the serialized
// native worker, and the continuation is resumed exactly once by that worker.
struct TerminalSurfaceRuntimeQueuedScreenTail: @unchecked Sendable {
    let request: TerminalSurfaceRuntimeScreenTailRequest
    let continuation: CheckedContinuation<String?, Never>
}
