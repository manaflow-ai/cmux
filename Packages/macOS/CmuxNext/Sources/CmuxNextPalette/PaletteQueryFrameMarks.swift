import CmuxNextSignposts
import Foundation

/// The typed query's signposts (``SignpostName/paletteQueryRows`` and ``SignpostName/paletteQueryAnswer``):
/// begun at the search field's edit, ended at the commit of the frame that first shows the query's final
/// ranked rows and its first contributed answer (the palette's view ends them, `PaletteContentView.render`).
/// A query typed past before its frame is never ended. Nothing is recorded when the key category is off.
struct PaletteQueryFrameMarks {
    private var rows: SignpostInterval?
    private var answer: SignpostInterval?
    /// What the next applied rows' frame ends: the rows interval, and the answer interval with its rows.
    private(set) var pendingRows: SignpostInterval?
    private(set) var pendingAnswer: (interval: SignpostInterval, rows: Int)?

    /// The query was edited: a new pair of intervals (the last query's, if still open, stay unended).
    mutating func edited(scope: String) {
        let signposter = Signposter.key
        guard signposter.isEnabled else { return }
        rows = signposter.begin(.paletteQueryRows, "scope=\(scope)")
        answer = signposter.begin(.paletteQueryAnswer, "scope=\(scope)")
        pendingRows = nil
        pendingAnswer = nil
    }

    /// A delivery on screen: its ranked rows are `final`, and it shows `answerRows` rows answering the query.
    mutating func delivered(final: Bool, answerRows: Int) {
        if final, let rows {
            pendingRows = rows
            self.rows = nil
        }
        if answerRows > 0, let answer {
            pendingAnswer = (answer, answerRows)
            self.answer = nil
        }
    }

    /// The marks the frame being applied ends (cleared).
    mutating func takePending() -> (rows: SignpostInterval?, answer: (interval: SignpostInterval, rows: Int)?) {
        defer {
            pendingRows = nil
            pendingAnswer = nil
        }
        return (pendingRows, pendingAnswer)
    }
}
