import CmuxMobileShell
import CoreGraphics

/// One positioned text run produced by thumbnail layout.
struct TerminalGridThumbnailRun: Equatable {
    let row: Int
    let column: Int
    let cellWidth: Int
    let frame: CGRect
    let text: String
    let style: PreviewGridStyle
}
