/// Why ``CookieImportService/run(_:)`` refused a run before any work started.
/// The App's handler binding prints any thrown error's description as the
/// refusal, so this reaches the CLI as `unavailable: <message>`, like the
/// daemon service's `ActionFailure` (which this target does not link).
struct CookieImportRefusal: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}
