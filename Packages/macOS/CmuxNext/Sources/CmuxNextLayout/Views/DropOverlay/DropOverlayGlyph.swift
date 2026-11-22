import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The drop overlay's glyphs: cmux icons at the size of the label beside them.
enum DropOverlayGlyph {
    static var side: CGFloat { .iconRowSize(forLabelPointSize: Typography.bodyEmphasized.pointSize) }

    static func image(_ name: IconName) -> NSImage { NSImage.icon(name, size: side) }
}
