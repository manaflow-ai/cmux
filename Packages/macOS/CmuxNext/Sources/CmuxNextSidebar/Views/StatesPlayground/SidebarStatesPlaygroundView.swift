import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground, Lawrence msg 19746): every sidebar row state at every
/// density and text size, light above dark, each cell the real row drawn by ``SidebarStatesPlaygroundRenderer``
/// with its trailing marks measured. Draw Again draws every sheet again from the current code and settings.
final class SidebarStatesPlaygroundView: NSView {
    private let renderer: SidebarStatesPlaygroundRenderer
    private let redraw = NSButton()
    private let scroll = NSScrollView()
    private let document = FlippedDocument()
    /// The sheets, light then dark.
    private(set) var sheets: [SidebarStatesPlaygroundAppearance: SidebarStatesPlaygroundSheetView] = [:]

    /// Draws every sheet with `renderer`.
    init(renderer: SidebarStatesPlaygroundRenderer) {
        self.renderer = renderer
        super.init(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        redraw.title = Strings.statesPlaygroundRefresh
        redraw.bezelStyle = .rounded
        redraw.target = self
        redraw.action = #selector(drawAgain)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        for view in [redraw, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            redraw.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.space4),
            redraw.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space6),
            scroll.topAnchor.constraint(equalTo: redraw.bottomAnchor, constant: Metrics.space4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        drawSheets()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The playground in its own window, sized for a wide screen.
    static func makeWindow(renderer: SidebarStatesPlaygroundRenderer) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = Strings.statesPlaygroundTitle
        window.contentView = SidebarStatesPlaygroundView(renderer: renderer)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    @objc private func drawAgain() { drawSheets() }

    /// Draws every column of both appearances again and stacks the sheets, light on top.
    func drawSheets() {
        document.subviews.forEach { $0.removeFromSuperview() }
        sheets = [:]
        var y: CGFloat = 0, width: CGFloat = 0
        for appearance in SidebarStatesPlaygroundAppearance.allCases {
            let columns = SidebarStatesPlaygroundColumn.all
            var cells: [SidebarStatesPlaygroundColumn: [SidebarStatesPlaygroundState: SidebarStatesPlaygroundCell]] = [:]
            for column in columns { cells[column] = renderer.cells(column, appearance) }
            let sheet = SidebarStatesPlaygroundSheetView(appearance: appearance, columns: columns, cells: cells)
            sheet.frame.origin = NSPoint(x: 0, y: y)
            document.addSubview(sheet)
            sheets[appearance] = sheet
            y = sheet.frame.maxY
            width = max(width, sheet.frame.width)
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: y)
    }
}

/// The scroll view's document, top-down so the light sheet sits at the top.
private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}
