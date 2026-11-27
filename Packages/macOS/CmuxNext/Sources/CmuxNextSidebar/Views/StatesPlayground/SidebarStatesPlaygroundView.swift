import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground, Lawrence msg 19746): every sidebar row state at every
/// density and text size, light above dark, each cell the real row drawn by ``SidebarStatesPlaygroundRenderer``
/// with its trailing marks measured. Draw Again draws every sheet again from the current code and settings.
final class SidebarStatesPlaygroundView: NSView {
    private let renderer: SidebarStatesPlaygroundRenderer
    /// The sections other packages draw (the Home filter), each as its own sheets below the favicon styles sheets.
    private let sections: [SidebarStatesPlaygroundSection]
    private let redraw = NSButton()
    private let scroll = NSScrollView()
    private let document = FlippedDocument()
    /// The sheets, light then dark.
    private(set) var sheets: [SidebarStatesPlaygroundAppearance: SidebarStatesPlaygroundSheetView] = [:]
    /// The favicon styles sheets (`sidebar.faviconStyle`, Lawrence msg 19869) below the sheets: per appearance, light
    /// then dark, one sheet per style in `SidebarFaviconStyle.allCases` order, each at every density and text size.
    private(set) var faviconSheets: [SidebarStatesPlaygroundAppearance: [SidebarStatesPlaygroundSheetView]] = [:]
    /// Each section's sheets, in section order, light then dark, below the favicon styles sheets.
    private(set) var sectionSheets: [SidebarStatesPlaygroundAppearance: [SidebarStatesPlaygroundSectionSheetView]] = [:]

    /// Draws every sheet with `renderer`.
    /// - Parameters:
    ///   - renderer: Draws the real sidebar for each column and appearance.
    ///   - sections: Sections other packages draw (``SidebarStatesPlaygroundSection``), below the sidebar's own sheets.
    init(renderer: SidebarStatesPlaygroundRenderer, sections: [SidebarStatesPlaygroundSection] = []) {
        self.renderer = renderer
        self.sections = sections
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
    static func makeWindow(renderer: SidebarStatesPlaygroundRenderer, sections: [SidebarStatesPlaygroundSection] = []) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = Strings.statesPlaygroundTitle
        window.contentView = SidebarStatesPlaygroundView(renderer: renderer, sections: sections)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    @objc private func drawAgain() { drawSheets() }

    /// Draws every column of both appearances again and stacks the sheets, light on top, then the favicon styles
    /// sheets (one sheet per `sidebar.faviconStyle`, every density and text size, the favicon rows only), light on top,
    /// then each section's sheets (every density and text size), light on top.
    func drawSheets() {
        document.subviews.forEach { $0.removeFromSuperview() }
        sheets = [:]
        faviconSheets = [:]
        sectionSheets = [:]
        var y: CGFloat = 0, width: CGFloat = 0
        func add(_ appearance: SidebarStatesPlaygroundAppearance, _ columns: [SidebarStatesPlaygroundColumn],
                 states: [SidebarStatesPlaygroundState], title: String?) -> SidebarStatesPlaygroundSheetView {
            var cells: [SidebarStatesPlaygroundColumn: [SidebarStatesPlaygroundState: SidebarStatesPlaygroundCell]] = [:]
            for column in columns { cells[column] = renderer.cells(column, appearance) }
            let sheet = SidebarStatesPlaygroundSheetView(appearance: appearance, columns: columns, cells: cells, states: states, title: title)
            sheet.frame.origin = NSPoint(x: 0, y: y)
            document.addSubview(sheet)
            y = sheet.frame.maxY
            width = max(width, sheet.frame.width)
            return sheet
        }
        for appearance in SidebarStatesPlaygroundAppearance.allCases {
            sheets[appearance] = add(appearance, SidebarStatesPlaygroundColumn.all, states: SidebarStatesPlaygroundState.allCases, title: nil)
        }
        for appearance in SidebarStatesPlaygroundAppearance.allCases {
            faviconSheets[appearance] = SidebarFaviconStyle.allCases.map { style in
                add(appearance, SidebarStatesPlaygroundColumn.favicons(style), states: SidebarStatesPlaygroundState.favicons,
                    title: Strings.statesPlaygroundFaviconStyle(SidebarStatesPlaygroundColumn.title(style), appearance: appearance.title))
            }
        }
        for section in sections {
            for appearance in SidebarStatesPlaygroundAppearance.allCases {
                let columns = SidebarStatesPlaygroundColumn.all
                var cells: [SidebarStatesPlaygroundColumn: [SidebarStatesPlaygroundLookCell]] = [:]
                for column in columns { cells[column] = renderer.lookCells(section, column, appearance) }
                let sheet = SidebarStatesPlaygroundSectionSheetView(appearance: appearance, title: section.title,
                                                                    lookTitles: section.looks.map(\.title), columns: columns, cells: cells)
                sheet.frame.origin = NSPoint(x: 0, y: y)
                document.addSubview(sheet)
                y = sheet.frame.maxY
                width = max(width, sheet.frame.width)
                sectionSheets[appearance, default: []].append(sheet)
            }
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: y)
    }
}

/// The scroll view's document, top-down so the light sheet sits at the top.
private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}
