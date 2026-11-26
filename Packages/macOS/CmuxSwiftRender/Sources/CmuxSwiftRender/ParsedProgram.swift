import SwiftSyntax

/// A parsed and operator-folded sidebar program, ready to interpret against a
/// data context without re-parsing.
///
/// Produced by ``SwiftViewInterpreter/parse(_:)`` and consumed by
/// ``SwiftViewInterpreter/evaluate(_:state:)``. Parsing and operator folding
/// are the source-only, expensive steps; caching a ``ParsedProgram`` lets a
/// host re-render against changing live data (for example a per-second clock
/// tick) without paying the parse cost on every frame.
///
/// ```swift
/// let interpreter = SwiftViewInterpreter()
/// let program = interpreter.parse(source)        // parse once
/// let node = interpreter.evaluate(program, state: liveData)  // cheap re-eval
/// ```
public struct ParsedProgram: Sendable {
    /// The folded syntax tree the interpreter walks.
    let file: SourceFileSyntax

    init(file: SourceFileSyntax) {
        self.file = file
    }
}
