public import CmuxNextSettings

/// The diff tabs' open timeline for the instant-surfaces bench (`diff_right`,
/// scripts/cmux-next/instant-new-surfaces-bench.py): the page calls `cmux.diff.shown {marks, files,
/// adopted}` once its first hunk is on screen (webviews/src/diff-viewer/openTiming.ts), and the host
/// marks its own steps of the open (`diff.session_open`, ...). DiffPageService owns one and gives it
/// to each tab's provider; both hooks are nil outside a bench run, so the op does nothing then.
public final class DiffOpenTimeline {
    public var onShown: ((JSONValue) -> Void)?
    public var onMark: ((String) -> Void)?

    public init() {}

    func mark(_ step: String) { onMark?(step) }
}

extension DiffPageProvider {
    static let shownOp = "cmux.diff.shown"

    /// Answers `cmux.diff.shown`.
    func shownCall(_ params: JSONValue) -> JSONValue {
        timeline?.onShown?(params)
        return ["ok": true]
    }

    func mark(_ step: String) { timeline?.mark(step) }
}
