import CmuxSwiftRender
import Foundation

/// Turns an ``InterpreterRequest`` into an ``InterpreterResponse`` by running
/// the ``SwiftViewInterpreter``.
///
/// This is the only logic the out-of-process worker runs. It is the worker's
/// single-threaded read-eval-write loop, so it caches the most recent parse:
/// the host re-renders on a timer with the same source but changing data, and
/// re-parsing unchanged source every tick is wasteful. (Reference type because
/// it holds that cache; it is confined to the worker's serial loop.)
public final class RenderInterpreterRunner {
    private let interpreter = SwiftViewInterpreter()
    private var cachedSource: String?
    private var cachedProgram: ParsedProgram?

    public init() {}

    /// Interprets `request.source` against `request.state` and returns the
    /// matching response, reusing a cached parse when the source is unchanged.
    public func run(_ request: InterpreterRequest) -> InterpreterResponse {
        // Test-only fault injection, gated behind environment variables the app
        // never sets. This lets crash/timeout isolation be verified through the
        // real process boundary (a worker that genuinely dies/hangs), which is
        // the property the whole package exists to provide.
        let environment = ProcessInfo.processInfo.environment
        if let crashToken = environment["CMUX_INTERPRETER_TEST_CRASH_TOKEN"],
           !crashToken.isEmpty, request.source == crashToken {
            fatalError("interpreter worker test crash sentinel")
        }
        if let hangToken = environment["CMUX_INTERPRETER_TEST_HANG_TOKEN"],
           !hangToken.isEmpty, request.source == hangToken {
            // Deterministic test-only hang to exercise the client's timeout.
            Thread.sleep(forTimeInterval: 3600)
        }

        let program: ParsedProgram
        if cachedSource == request.source, let cached = cachedProgram {
            program = cached
        } else {
            program = interpreter.parse(request.source)
            cachedSource = request.source
            cachedProgram = program
        }
        let node = interpreter.evaluate(program, state: request.state)
        return InterpreterResponse(id: request.id, node: node)
    }
}
