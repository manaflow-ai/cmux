/// Effective terminal grid the scripted host (``LivenessHostRouter``)
/// acknowledges for a `mobile.terminal.viewport` report in tests.
struct LivenessViewportReport: Sendable {
    var columns: Int
    var rows: Int
}
