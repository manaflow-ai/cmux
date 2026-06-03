import CmuxSwiftRender
import Foundation

/// Turns an ``InterpreterRequest`` into an ``InterpreterResponse`` by running
/// the ``SwiftViewInterpreter``.
///
/// This is the only logic the out-of-process worker runs. It is deliberately
/// pure (request in, response out) so the worker's `main` is a thin read-eval-
/// write loop and the run step is unit-testable in-process.
public struct RenderInterpreterRunner: Sendable {
    private let interpreter = SwiftViewInterpreter()

    public init() {}

    /// Interprets `request.source` against `request.state` and returns the
    /// matching response.
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

        let node = interpreter.evaluate(request.source, state: request.state)
        return InterpreterResponse(id: request.id, node: node)
    }
}
