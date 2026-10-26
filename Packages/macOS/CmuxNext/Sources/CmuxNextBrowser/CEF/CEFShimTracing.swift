/// The in-process shim's three tracing exports (``CEFShimLibrary/tracing``, p09-observability task 050), used
/// on the main actor (``CEFTracing``): each call posts to Chromium's UI thread and awaits its one callback.
nonisolated struct CEFShimTracing {
    typealias BeginFn = @convention(c) (UnsafePointer<CChar>?, CEFShimLibrary.TraceStartedFn?, UnsafeMutableRawPointer?) -> Int32
    typealias EndFn = @convention(c) (UnsafePointer<CChar>?, CEFShimLibrary.TraceWrittenFn?, UnsafeMutableRawPointer?) -> Int32

    private let beginFn: BeginFn
    private let endFn: EndFn
    private let nowFn: @convention(c) () -> Int64

    init(begin: BeginFn, end: EndFn, now: @convention(c) () -> Int64) {
        beginFn = begin
        endFn = end
        nowFn = now
    }

    /// `cmux_cef_begin_tracing`; false when nothing was posted or Chromium refused.
    func begin(categories: String) async -> Bool {
        await CEFTraceReply<Bool>.call(failure: false) { context in
            categories.withCString {
                beginFn($0, { reply, ok in
                    guard let reply else { return }
                    CEFTraceReply<Bool>.resume(reply, with: ok == 1)
                }, context)
            }
        }
    }

    /// `cmux_cef_end_tracing`; the finished file, nil when nothing was posted or no recording ran.
    func end(path: String) async -> String? {
        await CEFTraceReply<String?>.call(failure: nil) { context in
            path.withCString {
                endFn($0, { reply, written in
                    guard let reply else { return }
                    // The path is valid only during this call: copied before it returns.
                    CEFTraceReply<String?>.resume(reply, with: written.map { String(cString: $0) })
                }, context)
            }
        }
    }

    /// `cmux_cef_now_trace_us`: a clock read, any thread.
    func now() -> Int64 { nowFn() }
}

/// One shim completion. The C callback (on Chromium's UI thread, or the thread that drops the request), or
/// the caller when nothing was posted, takes it back exactly once: the shim runs a posted callback exactly
/// once and an unposted one never (CEFShim/src/trace_request.h).
nonisolated final class CEFTraceReply<Value: Sendable>: Sendable {
    private let continuation: CheckedContinuation<Value, Never>

    private init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    /// Runs `post` with a retained context; a return other than 1 (nothing posted) answers `failure`.
    static func call(failure: Value, _ post: (UnsafeMutableRawPointer) -> Int32) async -> Value {
        await withCheckedContinuation { continuation in
            let context = Unmanaged.passRetained(CEFTraceReply(continuation)).toOpaque()
            if post(context) != 1 { resume(context, with: failure) }
        }
    }

    /// Takes the context back and answers its caller.
    static func resume(_ context: UnsafeMutableRawPointer, with value: Value) {
        Unmanaged<CEFTraceReply<Value>>.fromOpaque(context).takeRetainedValue().continuation.resume(returning: value)
    }
}
