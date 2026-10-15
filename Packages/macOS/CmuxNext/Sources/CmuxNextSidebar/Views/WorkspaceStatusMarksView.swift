import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// Group by Status's marks in a workspace row's trailing cluster (`WorkspaceRowStatusMarks`),
/// right to left: the warning on Needs you rows, the status glyph, then the computer the session
/// runs on. Urgent marks take the palette's attention and danger tokens (themed, apart from
/// group colors); the rest are tertiary text. No motion of its own beyond the shared indicator's.
final class WorkspaceStatusMarksView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.sidebar.workspace.statusMarks")

    /// The shared indicator, for states it draws (working, waiting, error, success, busy, paused).
    let glyph = StatusIndicatorView()
    /// Done or No agent at rest: a quiet glyph, so every row has one.
    let quiet = NSImageView()
    let warning = NSImageView()
    let machine = NSImageView()
    private(set) var marks: WorkspaceRowStatusMarks?

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        identifier = Self.identifier
        setAccessibilityElement(false)
        glyph.tracksWindowOcclusion = true
        glyph.identifier = NSUserInterfaceItemIdentifier("statusGlyph")
        quiet.identifier = NSUserInterfaceItemIdentifier("statusGlyph.quiet")
        warning.identifier = NSUserInterfaceItemIdentifier("statusWarning")
        for view in [quiet, warning, machine] {
            view.imageScaling = .scaleProportionallyDown
            view.setAccessibilityElement(false)
        }
        [machine, glyph, quiet, warning].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(_ marks: WorkspaceRowStatusMarks) {
        guard marks != self.marks else { return }
        self.marks = marks
        let size = CGFloat.iconRowSize(forLabelPointSize: SidebarStyle.indicatorSize - Metrics.space1)
        let state = marks.indicator
        glyph.configure(state ?? .idle)
        let quietIcon: IconName = marks.bucket == .done ? .statusComplete : .stateIdle
        quiet.image = NSImage.icon(quietIcon, size: size)
        quiet.isHidden = drawsIndicator
        warning.image = marks.warns ? NSImage.icon(.statusWarning, size: size) : nil
        warning.isHidden = !marks.warns
        let machineIcon: IconName? = switch marks.machine {
        case .local?: .machineLocal
        case .cloud?: .cloud
        case .ssh?, .server?: .machineRemote
        case nil: nil
        }
        machine.image = machineIcon.map { NSImage.icon($0, size: size) }
        machine.isHidden = machineIcon == nil
        machine.identifier = NSUserInterfaceItemIdentifier("statusMachine.\(machineIcon?.rawValue ?? "none")")
        needsLayout = true
        needsDisplay = true
    }

    /// Whether the status glyph is the shared indicator's (else the quiet one).
    private var drawsIndicator: Bool { marks?.indicator != nil && glyph.showsGlyph }

    private var parts: [NSView] {
        [warning.isHidden ? nil : warning, drawsIndicator ? glyph : quiet, machine.isHidden ? nil : machine].compactMap { $0 }
    }

    var preferredWidth: CGFloat {
        let views = parts
        return views.reduce(0) { $0 + side(of: $1) } + CGFloat(max(0, views.count - 1)) * Metrics.space1
    }

    private func side(of view: NSView) -> CGFloat {
        view === glyph ? SidebarStyle.statusGlyphSize : SidebarStyle.indicatorSize
    }

    override func layout() {
        super.layout()
        quiet.isHidden = drawsIndicator // the indicator hides itself when it draws nothing
        var trailing = bounds.maxX
        for view in parts {
            let s = side(of: view)
            view.frame = NSRect(x: trailing - s, y: (bounds.height - s) / 2, width: s, height: s)
            trailing -= s + Metrics.space1
        }
    }

    override func updateLayer() {
        performWithTheme {
            warning.contentTintColor = marks?.isError == true ? Palette.danger : Palette.attention
            quiet.contentTintColor = Palette.textTertiary
            machine.contentTintColor = Palette.textTertiary
        }
    }
}
