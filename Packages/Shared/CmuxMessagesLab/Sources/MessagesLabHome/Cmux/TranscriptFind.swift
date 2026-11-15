// cmux: Find in a Home chat (Cmd-F). Not a vendored file.
import AppKit

/// Find in the Home transcript (not built yet: finds nothing).
final class TranscriptFind {
    private weak var controller: ChatController?
    init(controller: ChatController) { self.controller = controller }
    func search(_ query: String) {}
    func step(forward: Bool) {}
    func rowsChanged() {}
    var position: (current: Int, total: Int) { (0, 0) }
    func draw(_ cell: RowCell) {}
}

extension RowCell {
    /// The find highlight paths this cell draws now (tests).
    var findHighlightPaths: (all: CGPath?, current: CGPath?) { (nil, nil) }
}
