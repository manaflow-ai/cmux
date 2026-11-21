// cmux: the Chief composer's `/` menu over the message box: each matching skill's command, its
// source and its description, the selected row in the accent colour. Solid in light and dark (no
// glass: rows under it never show through, Lawrence 2026-11-07 "this ui transparency looks bad").
// Not a vendored file.
import AppKit

/// The `/` menu's rows, drawn in one view; the controller owns the state (``SlashSkillMenu``).
final class SlashSkillMenuView: NSView {
    static let gap: CGFloat = 6
    static let rowHeight: CGFloat = 42
    static let visibleRows = 6
    private static let inset: CGFloat = 5

    /// A click on row `index` of the matches.
    var onPick: (Int) -> Void = { _ in }
    /// The pointer moved over row `index`.
    var onHover: (Int) -> Void = { _ in }

    private(set) var state: SlashSkillMenu?
    /// The first match shown (the list scrolls to keep the selection in view).
    private(set) var firstVisible = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(CmuxStrings.slashSkillsTitle)
        updateColors()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.shadowColor = NSColor.black.cgColor
        }
    }

    /// Shows `menu`, keeping its selection in view.
    func show(_ menu: SlashSkillMenu) {
        state = menu
        let n = menu.matches.count
        let sel = menu.selected
        if sel < firstVisible { firstVisible = sel }
        if sel >= firstVisible + Self.visibleRows { firstVisible = sel - Self.visibleRows + 1 }
        firstVisible = max(0, min(firstVisible, max(0, n - Self.visibleRows)))
        setAccessibilityValue(menu.choice.map { "/\($0.name)" })
        needsDisplay = true
    }

    /// The menu's height for `menu`: up to ``visibleRows`` rows, one for "no match".
    static func height(for menu: SlashSkillMenu) -> CGFloat {
        CGFloat(max(1, min(visibleRows, menu.matches.count))) * rowHeight + 2 * inset
    }

    private func rowRect(_ shown: Int) -> CGRect {
        CGRect(x: Self.inset, y: Self.inset + CGFloat(shown) * Self.rowHeight, width: bounds.width - 2 * Self.inset, height: Self.rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let menu = state else { return }
        let nameFont = HomeFonts.system(ofSize: 13, weight: .semibold)
        let smallFont = HomeFonts.system(ofSize: 11)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        guard !menu.matches.isEmpty else {
            let text = (menu.isLoading ? CmuxStrings.slashSkillsLoading
                : menu.loadFailed ? CmuxStrings.slashSkillsFailed : CmuxStrings.slashSkillsNoMatch(menu.query)) as NSString
            let r = rowRect(0).insetBy(dx: 10, dy: 0)
            text.draw(in: CGRect(x: r.minX, y: r.midY - 8, width: r.width, height: 18),
                      withAttributes: [.font: HomeFonts.system(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para])
            return
        }
        for (index, skill) in menu.matches.enumerated().dropFirst(firstVisible).prefix(Self.visibleRows) {
            let r = rowRect(index - firstVisible)
            let selected = index == menu.selected
            if selected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            }
            let primary: NSColor = selected ? .white : .labelColor
            let secondary: NSColor = selected ? NSColor.white.withAlphaComponent(0.82) : .secondaryLabelColor
            let tag = Self.sourceLabel(skill.source) as NSString
            let tagAttrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: secondary]
            let tagWidth = ceil(tag.size(withAttributes: tagAttrs).width)
            let x = r.minX + 10, right = r.maxX - 10
            tag.draw(at: CGPoint(x: right - tagWidth, y: r.minY + 6), withAttributes: tagAttrs)
            ("/" + skill.name as NSString).draw(in: CGRect(x: x, y: r.minY + 5, width: max(20, right - tagWidth - 10 - x), height: 17),
                                                withAttributes: [.font: nameFont, .foregroundColor: primary, .paragraphStyle: para])
            (skill.summary as NSString).draw(in: CGRect(x: x, y: r.minY + 22, width: right - x, height: 15),
                                             withAttributes: [.font: smallFont, .foregroundColor: secondary, .paragraphStyle: para])
        }
    }

    /// The source tag at a row's right: Chief, Claude, or the plugin's name.
    static func sourceLabel(_ source: SlashSkill.Source) -> String {
        switch source {
        case .chief: CmuxStrings.slashSkillsSourceChief
        case .claude: CmuxStrings.slashSkillsSourceClaude
        case let .plugin(name): name
        }
    }

    private func matchIndex(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        guard let menu = state else { return nil }
        let shown = min(Self.visibleRows, menu.matches.count - firstVisible)
        return (0..<max(0, shown)).first { rowRect($0).contains(p) }.map { firstVisible + $0 }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { if let i = matchIndex(at: event) { onHover(i) } }
    override func mouseDown(with event: NSEvent) { if let i = matchIndex(at: event) { onPick(i) } }
    override func scrollWheel(with event: NSEvent) {
        guard let menu = state else { return }
        let step = event.scrollingDeltaY > 0 ? -1 : (event.scrollingDeltaY < 0 ? 1 : 0)
        firstVisible = max(0, min(firstVisible + step, max(0, menu.matches.count - Self.visibleRows)))
        needsDisplay = true
    }
}
