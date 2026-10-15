import AppKit
import CmuxNextDesign

/// Group by Status's elbow (`SidebarGrouping.elbowsChildren`, Debug `sidebar.statusElbow`): the CLI connector `⎿` a child
/// agent session's row draws at its leading edge, in tertiary ink, so the row reads as hanging off
/// the parent row above it, as a tool result hangs off its call in Claude Code's output. It takes
/// the leading slot (the row's content starts after it), drawn by the row only while its content
/// says so (`WorkspaceRowContent.elbow`). Decorative: VoiceOver reads the row as before.
final class SidebarElbowView: NSView {
    static let glyph = "⎿"

    private static var attributes: [NSAttributedString.Key: Any] { [.font: SidebarStyle.titleFont] }

    /// The glyph's drawn size in the row's title font.
    static var glyphSize: NSSize {
        let size = (glyph as NSString).size(withAttributes: attributes)
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            var attributes = Self.attributes
            attributes[.foregroundColor] = Palette.textTertiary
            (Self.glyph as NSString).draw(at: .zero, withAttributes: attributes)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension WorkspaceRowView {
    /// Lays out the elbow of a row whose content draws one, centered on the title's line of
    /// `head`, and returns how far the row's content starts after the leading inset; 0, with no
    /// elbow shown, otherwise. The elbow view is made the first time a row draws one.
    func layoutElbow(head: NSRect) -> CGFloat {
        let existing = subviews.lazy.compactMap { $0 as? SidebarElbowView }.first
        guard lastConfiguration?.1.content?.elbow == true, !isShowingPlaceholder else {
            existing?.isHidden = true
            return 0
        }
        let elbow = existing ?? {
            let view = SidebarElbowView()
            addSubview(view)
            return view
        }()
        let size = SidebarElbowView.glyphSize
        let center = textMetrics(head: head).center
        elbow.isHidden = false
        elbow.frame = NSRect(x: SidebarStyle.horizontalInset, y: center - size.height / 2, width: size.width, height: size.height)
        elbow.needsDisplay = true
        return size.width + Metrics.space1
    }
}
