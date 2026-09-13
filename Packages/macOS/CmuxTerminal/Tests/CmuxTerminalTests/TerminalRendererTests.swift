import Testing

/// Renderer suites share native test instrumentation; serialization must cover
/// the whole family, including asynchronous parser and callback tests.
@Suite(.serialized)
struct TerminalRendererTests {}
