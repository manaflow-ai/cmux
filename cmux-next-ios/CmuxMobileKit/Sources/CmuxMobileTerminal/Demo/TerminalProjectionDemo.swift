// DEBUG and Demo builds only: never compiled into Production.
#if os(iOS) && DEBUG
import CmuxMobileDesign
import SwiftUI
import UIKit

/// DEBUG prototype for a design question (Leo, 2026-11-12): should the phone
/// resize the Mac's terminal to its own width, or project the Mac's grid?
/// Three ways to show one Mac session (a 120×40 pane) on the phone, each drawn
/// by the real Ghostty surface from the same mock byte stream:
///
/// - A, Resize (today): the Mac's PTY takes the phone's grid; every program
///   redraws at the phone's columns.
/// - B, Reflow: the Mac keeps 120 columns. The phone parses the stream in its
///   own VT at 120 columns, then re-wraps its lines at the phone's width
///   (Ghostty's reflow on resize). A full-screen app (alternate screen)
///   cannot be re-wrapped, so it is shown at 120 columns, native font, and
///   pans sideways with a column indicator.
/// - C, Scaled: the Mac's 120-column grid scaled to the phone's width; pinch
///   to zoom, pan, double-tap to zoom on a spot (again to zoom out).
///
/// Launch with `-CmuxMobileProjectionDemo SPEC`, SPEC one of `a-shell`,
/// `a-tui`, `b-shell`, `b-tui`, `c-shell`, `c-tui`, with `-zoom` on a C spec
/// to open zoomed on the cursor line (`c-shell-zoom`). The segmented controls
/// switch live. Never changes how a real terminal is shown.
public struct TerminalProjectionDemoRoot: View {
    @State private var variant: TerminalProjectionVariant
    @State private var content: TerminalProjectionContent
    @State private var caption = ""
    private let startZoomed: Bool

    public static var isRequested: Bool { CommandLine.arguments.contains("-CmuxMobileProjectionDemo") }

    public init() {
        let args = CommandLine.arguments
        var spec = "a-shell"
        if let index = args.firstIndex(of: "-CmuxMobileProjectionDemo"), index + 1 < args.count { spec = args[index + 1] }
        let words = spec.lowercased().split(separator: "-").map(String.init)
        _variant = State(initialValue: words.first.flatMap(TerminalProjectionVariant.init(rawValue:)) ?? .resize)
        _content = State(initialValue: words.contains("tui") ? .tui : .shell)
        startZoomed = words.contains("zoom")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Variant", selection: $variant) {
                    ForEach(TerminalProjectionVariant.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Content", selection: $content) {
                    Text("Shell + Claude Code").tag(TerminalProjectionContent.shell)
                    Text("htop (alt screen)").tag(TerminalProjectionContent.tui)
                }
                .pickerStyle(.segmented)
                Text(caption)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            }
            .padding(.horizontal, 10)
            TerminalProjectionRepresentable(variant: variant, content: content, startZoomed: startZoomed) { text in
                caption = text
            }
            .id("\(variant.rawValue)-\(content.rawValue)")
        }
        .background(Color(uiColor: CmuxMobileGhosttyApp.background).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

enum TerminalProjectionVariant: String, CaseIterable {
    case resize = "a", reflow = "b", scaled = "c"

    var title: String {
        switch self {
        case .resize: "A Resize"
        case .reflow: "B Reflow"
        case .scaled: "C Scaled"
        }
    }
}

enum TerminalProjectionContent: String {
    case shell, tui
}

private struct TerminalProjectionRepresentable: UIViewRepresentable {
    let variant: TerminalProjectionVariant
    let content: TerminalProjectionContent
    let startZoomed: Bool
    let onCaption: (String) -> Void

    func makeUIView(context: Context) -> TerminalProjectionView {
        TerminalProjectionView(variant: variant, content: content, startZoomed: startZoomed, onCaption: onCaption)
    }

    func updateUIView(_ view: TerminalProjectionView, context: Context) {}
}

/// One variant: the real Ghostty surface in a scroll view (pan for B's alt
/// screen, zoom for C).
@MainActor
final class TerminalProjectionView: UIView, UIScrollViewDelegate {
    /// The Mac pane's grid.
    static let macColumns = 120
    static let macRows = 40

    private let variant: TerminalProjectionVariant
    private let content: TerminalProjectionContent
    private let startZoomed: Bool
    private let onCaption: (String) -> Void
    private let scroll = UIScrollView()
    private let surface = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
    private let indicator = UILabel()
    private var cell: CGSize = .zero
    private var focus = (row: 0, column: 0)
    private var phoneColumns = 0

    init(variant: TerminalProjectionVariant, content: TerminalProjectionContent, startZoomed: Bool, onCaption: @escaping (String) -> Void) {
        self.variant = variant
        self.content = content
        self.startZoomed = startZoomed
        self.onCaption = onCaption
        super.init(frame: .zero)
        backgroundColor = CmuxMobileGhosttyApp.background
        clipsToBounds = true
        scroll.delegate = self
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = CmuxMobileGhosttyApp.background
        scroll.bouncesZoom = true
        scroll.alwaysBounceVertical = false
        scroll.indicatorStyle = .white
        addSubview(scroll)
        // The scroll view takes every touch: pan and zoom are the prototype.
        surface.isUserInteractionEnabled = false
        scroll.addSubview(surface)
        indicator.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        indicator.textColor = .white
        indicator.backgroundColor = UIColor(white: 0.18, alpha: 0.92)
        indicator.textAlignment = .center
        indicator.layer.cornerRadius = 9
        indicator.layer.masksToBounds = true
        indicator.isHidden = true
        addSubview(indicator)
        if variant == .scaled {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
            doubleTap.numberOfTapsRequired = 2
            scroll.addGestureRecognizer(doubleTap)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        layoutIndicator()
        guard cell == .zero, bounds.width > 0, bounds.height > 0, window != nil else { return }
        // The surface is made once it is in a window; its cells are measured then.
        let measured = surface.cellSize
        guard measured.width > 0, measured.height > 0 else {
            Task { @MainActor [weak self] in self?.setNeedsLayout() }
            return
        }
        cell = measured
        configure()
    }

    private func gridSize(columns: Int, rows: Int) -> CGSize {
        // Ghostty fits floor(width / cell) columns: half a cell more makes exactly `columns`.
        CGSize(width: (CGFloat(columns) + 0.5) * cell.width, height: (CGFloat(rows) + 0.5) * cell.height)
    }

    private func setSurface(_ size: CGSize) {
        surface.frame = CGRect(origin: .zero, size: size)
        scroll.contentSize = size
        // Ghostty gets the grid now, before the bytes are parsed at the old one.
        surface.layoutIfNeeded()
    }

    private func configure() {
        phoneColumns = max(20, Int(floor(bounds.width / cell.width)))
        let phoneRows = max(10, Int(floor(bounds.height / cell.height)))
        let mac = (Self.macColumns, Self.macRows)
        let font = CmuxMobilePreferences.terminalFontSize()
        let cellText = String(format: "%.1f×%.1f pt", cell.width, cell.height)
        switch variant {
        case .resize:
            let frame = TerminalProjectionMock.frame(content, columns: phoneColumns, rows: phoneRows)
            setSurface(gridSize(columns: phoneColumns, rows: phoneRows))
            surface.feed(frame.bytes)
            caption("A · Resize (today). The Mac's PTY takes this phone's grid, \(phoneColumns)×\(phoneRows); every program redraws at \(phoneColumns) columns, and the Mac pane shrinks to match. Font \(font) pt, cell \(cellText).")
        case .reflow:
            let frame = TerminalProjectionMock.frame(content, columns: mac.0, rows: mac.1)
            setSurface(gridSize(columns: mac.0, rows: mac.1))
            if content == .shell {
                // The Mac's 120-column rows (its VT's soft wraps), each re-wrapped
                // cell by cell at the phone's width: what reflowing a local VT gives.
                let reflowed = TerminalProjectionMock.reflowedShell(macColumns: mac.0, phoneColumns: phoneColumns)
                setSurface(gridSize(columns: phoneColumns, rows: phoneRows))
                caption("B · Reflow. The Mac keeps \(mac.0)×\(mac.1). The phone keeps its rows at \(mac.0) columns and re-wraps each one at \(phoneColumns), cell by cell. The programs still laid out for \(mac.0): boxes and columns break. Font \(font) pt.")
                surface.feed(reflowed)
                showIndicator("\(mac.0) cols re-wrapped at \(phoneColumns)")
            } else {
                caption("B · Reflow, alt screen. A full-screen app cannot be re-wrapped: it is shown at the Mac's \(mac.0)×\(mac.1), native \(font) pt font, panned sideways (indicator). Normal-screen output re-wraps.")
                surface.feed(frame.bytes)
                scroll.showsHorizontalScrollIndicator = true
                updatePanIndicator()
            }
        case .scaled:
            let frame = TerminalProjectionMock.frame(content, columns: mac.0, rows: mac.1)
            focus = frame.focus
            let size = gridSize(columns: mac.0, rows: mac.1)
            setSurface(size)
            let fit = bounds.width / size.width
            scroll.minimumZoomScale = fit
            scroll.maximumZoomScale = 1.25
            scroll.zoomScale = fit
            let effective = String(format: "%.1f pt", CGFloat(font) * fit)
            let effectiveCell = String(format: "%.1f×%.1f pt", cell.width * fit, cell.height * fit)
            caption("C · Scaled. The Mac's \(mac.0)×\(mac.1) grid scaled ×\(String(format: "%.2f", fit)) to fit: cell \(effectiveCell), font ≈ \(effective) (drawn at \(font) pt). Pinch to zoom and pan; double-tap zooms on a spot.")
            surface.feed(frame.bytes, completion: { [weak self] in
                guard let self, self.startZoomed else { return }
                self.zoom(onRow: self.focus.row, column: self.focus.column, animated: false)
            })
            updateZoomIndicator()
        }
    }

    private func caption(_ text: String) {
        Task { @MainActor [weak self] in self?.onCaption(text) }
    }

    // MARK: Indicator

    private func showIndicator(_ text: String) {
        indicator.text = text
        indicator.isHidden = false
        setNeedsLayout()
    }

    private func layoutIndicator() {
        guard !indicator.isHidden else { return }
        let size = indicator.intrinsicContentSize
        let width = min(bounds.width - 16, size.width + 18)
        indicator.frame = CGRect(x: bounds.width - width - 8, y: bounds.height - 30, width: width, height: 20)
    }

    private func visibleColumns() -> (first: Int, last: Int) {
        let scale = max(scroll.zoomScale, 0.01)
        let width = cell.width * scale
        guard width > 0 else { return (1, 1) }
        let first = Int(floor(scroll.contentOffset.x / width)) + 1
        let last = min(Self.macColumns, Int(floor((scroll.contentOffset.x + bounds.width) / width)))
        return (max(1, first), max(1, last))
    }

    private func updatePanIndicator() {
        let columns = visibleColumns()
        let left = columns.first > 1 ? "◀ " : "  "
        let right = columns.last < Self.macColumns ? " ▶" : "  "
        showIndicator("\(left)cols \(columns.first)–\(columns.last) of \(Self.macColumns)\(right) · not reflowed")
    }

    private func updateZoomIndicator() {
        let scale = String(format: "×%.2f", scroll.zoomScale)
        if scroll.zoomScale <= scroll.minimumZoomScale * 1.02 {
            showIndicator("\(scale) · all \(Self.macColumns) cols · pinch or double-tap")
        } else {
            let columns = visibleColumns()
            showIndicator("\(scale) · cols \(columns.first)–\(columns.last) of \(Self.macColumns)")
        }
    }

    // MARK: Zoom and pan

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        variant == .scaled ? surface : nil
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard cell != .zero else { return }
        if variant == .scaled { updateZoomIndicator() }
        if variant == .reflow, content == .tui { updatePanIndicator() }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard cell != .zero else { return }
        updateZoomIndicator()
    }

    /// Zooms to the phone's own font size (×1) around one cell.
    private func zoom(onRow row: Int, column: Int, animated: Bool) {
        let width = bounds.width, height = bounds.height
        let center = CGPoint(x: (CGFloat(column) + 0.5) * cell.width, y: (CGFloat(row) + 0.5) * cell.height)
        let x = min(max(0, center.x - width * 0.25), max(0, surface.bounds.width - width))
        let y = min(max(0, center.y - height / 2), max(0, surface.bounds.height - height))
        scroll.zoom(to: CGRect(x: x, y: y, width: width, height: height), animated: animated)
        updateZoomIndicator()
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard cell != .zero else { return }
        if scroll.zoomScale > scroll.minimumZoomScale * 1.02 {
            scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            return
        }
        let point = recognizer.location(in: surface)
        zoom(onRow: Int(point.y / cell.height), column: Int(point.x / cell.width), animated: true)
    }
}

// MARK: - Mock content

/// The mock Mac session, formatted for a grid of `columns` the way the
/// programs themselves would (ls columns, Claude Code's word wrap and boxes,
/// htop's meters), so A shows what a resize gets and B/C what 120 columns get.
enum TerminalProjectionMock {
    struct Frame {
        var bytes: Data
        /// The row and column C zooms on: the cursor (shell) or the selected process (htop).
        var focus: (row: Int, column: Int)
    }

    private static let esc = "\u{1B}["

    /// One line of styled spans; its width is its character count (every
    /// character here is one cell wide).
    private struct Line {
        var spans: [(sgr: String, text: String)] = []

        init(_ spans: [(sgr: String, text: String)] = []) { self.spans = spans }
        init(_ text: String, _ sgr: String = "0") { spans = [(sgr, text)] }

        var width: Int { spans.reduce(0) { $0 + $1.text.count } }

        mutating func add(_ text: String, _ sgr: String = "0") { spans.append((sgr, text)) }

        func padded(to width: Int, _ sgr: String = "0") -> Line {
            var line = self
            if line.width < width { line.add(String(repeating: " ", count: width - line.width), sgr) }
            return line
        }

        /// The line in pieces of `width` cells (the last one shorter).
        func chunks(of width: Int) -> [Line] {
            guard width > 0, self.width > width else { return [self] }
            var out: [Line] = [], current = Line()
            for span in spans {
                var rest = Substring(span.text)
                while !rest.isEmpty {
                    let room = width - current.width
                    current.add(String(rest.prefix(room)), span.sgr)
                    rest = rest.dropFirst(room)
                    if current.width == width { out.append(current); current = Line() }
                }
            }
            if current.width > 0 { out.append(current) }
            return out
        }

        /// Without its trailing unstyled spaces.
        func trimmingTrailingBlanks() -> Line {
            var line = self
            while let last = line.spans.last, last.sgr == "0" {
                let text = String(last.text.reversed().drop(while: { $0 == " " }).reversed())
                if text.isEmpty { line.spans.removeLast(); continue }
                line.spans[line.spans.count - 1].text = text
                break
            }
            return line
        }

        func truncated(to width: Int) -> Line {
            var out = Line(), left = width
            for span in spans where left > 0 {
                let text = String(span.text.prefix(left))
                out.add(text, span.sgr)
                left -= text.count
            }
            return out
        }

        var rendered: String {
            spans.map { "\(TerminalProjectionMock.esc)0;\($0.sgr)m\($0.text)" }.joined() + "\(TerminalProjectionMock.esc)0m"
        }
    }

    /// B: the shell frame as the Mac's VT holds it (rows of `macColumns`,
    /// long lines soft-wrapped there, trailing blanks dropped), each row
    /// re-wrapped at `phoneColumns` with its styles.
    static func reflowedShell(macColumns: Int, phoneColumns: Int) -> Data {
        var rows: [Line] = []
        for line in shellLines(width: macColumns) {
            for macRow in line.chunks(of: macColumns) {
                let trimmed = macRow.trimmingTrailingBlanks()
                rows += trimmed.width == 0 ? [trimmed] : trimmed.chunks(of: phoneColumns)
            }
        }
        var text = "\u{1B}c" + rows.map(\.rendered).joined(separator: "\r\n")
        text += "\(esc)2A\r\(esc)4C"
        return Data(text.utf8)
    }

    static func frame(_ content: TerminalProjectionContent, columns: Int, rows: Int) -> Frame {
        switch content {
        case .shell: shell(columns: columns, rows: rows)
        case .tui: htop(columns: columns, rows: rows)
        }
    }

    // MARK: Shell and Claude Code (normal screen)

    private static func prompt(_ command: String) -> Line {
        Line([("1;36", "~/src/app"), ("0;35", " main"), ("0", " % "), ("0", command)])
    }

    /// Words wrapped at `width`, the first line after `first`, the rest after `rest`.
    private static func wrap(_ text: String, width: Int, first: Line, rest: String, sgr: String = "0") -> [Line] {
        var lines: [Line] = [], line = first, empty = true
        for word in text.split(separator: " ").map(String.init) {
            let gap = empty ? 0 : 1
            if !empty, line.width + gap + word.count > width {
                lines.append(line)
                line = Line(rest)
                empty = true
            }
            line.add((empty ? "" : " ") + word, sgr)
            empty = false
        }
        lines.append(line)
        return lines
    }

    private static func boxed(_ lines: [Line], width: Int, sgr: String) -> [Line] {
        let inner = max(4, width - 4)
        var out = [Line("╭" + String(repeating: "─", count: width - 2) + "╮", sgr)]
        for line in lines {
            var row = Line("│ ", sgr)
            row.spans += line.truncated(to: inner).padded(to: inner).spans
            row.add(" │", sgr)
            out.append(row)
        }
        out.append(Line("╰" + String(repeating: "─", count: width - 2) + "╯", sgr))
        return out
    }

    private static func lsColumns(width: Int) -> [Line] {
        let names = ["Cargo.lock", "Cargo.toml", "LICENSE", "Makefile", "README.md", "assets/", "benches/", "build.rs",
                     "crates/", "docs/", "examples/", "fixtures/", "proto/", "rust-toolchain.toml", "scripts/", "src/",
                     "target/", "tests/", "tools/", "web/"]
        let cellWidth = (names.map(\.count).max() ?? 8) + 2
        let perRow = max(1, width / cellWidth)
        let rows = (names.count + perRow - 1) / perRow
        return (0..<rows).map { row in
            var line = Line()
            for column in 0..<perRow {
                let index = column * rows + row
                guard index < names.count else { continue }
                let name = names[index]
                let isDir = name.hasSuffix("/")
                let shown = isDir ? String(name.dropLast()) : name
                line.add(shown, isDir ? "1;34" : "0")
                if column < perRow - 1 { line.add(String(repeating: " ", count: cellWidth - shown.count)) }
            }
            return line
        }
    }

    private static func shell(columns width: Int, rows: Int) -> Frame {
        let lines = shellLines(width: width)
        return render(lines, width: width, rows: rows)
    }

    private static func shellLines(width: Int) -> [Line] {
        var lines: [Line] = []
        lines.append(prompt("ls"))
        lines += lsColumns(width: width)
        lines.append(prompt("cargo build --release 2>&1 | tail -3"))
        // Raw long lines: the terminal itself wraps these.
        lines.append(Line([("1;33", "warning"), ("1", ": unused variable: `scale` --> crates/link/src/viewport.rs:214:9 (help: prefix it with an underscore: `_scale`)")]))
        lines.append(Line("   Compiling link v0.9.3 (/Users/leo/src/app/crates/link)", "1;32"))
        lines.append(Line([("1;32", "    Finished"), ("0", " `release` profile [optimized] target(s) in 41.27s")]))
        lines.append(prompt("claude"))
        lines += boxed([
            Line([("38;5;209", "✻"), ("1", " Welcome to Claude Code!")]),
            Line(""),
            Line("  /help for help, /status for your current setup", "2"),
            Line(""),
            Line("  cwd: /Users/leo/src/app", "2"),
        ], width: width, sgr: "38;5;209")
        lines.append(Line(""))
        lines += wrap("fix the flaky resize test in the viewport tests, it fails about one run in five", width: width, first: Line("> ", "2"), rest: "  ", sgr: "2")
        lines.append(Line(""))
        lines += wrap("Read(crates/link/src/viewport.rs)", width: width, first: Line("⏺ ", "32"), rest: "  ", sgr: "1")
        lines.append(Line("  ⎿  Read 214 lines (ctrl+r to expand)", "2"))
        lines.append(Line(""))
        lines += wrap("The test assumes the phone always claims its own grid, but a pane pinned to the Mac keeps 120 columns, so the pan math runs against the wrong width. I'll pin the grid in the fixture and assert the pan clamps at the last column.", width: width, first: Line("⏺ ", "0"), rest: "  ")
        lines.append(Line(""))
        lines += wrap("Update(crates/link/src/viewport.rs)", width: width, first: Line("⏺ ", "32"), rest: "  ", sgr: "1")
        lines += wrap("Updated crates/link/src/viewport.rs with 2 additions and 1 removal", width: width, first: Line("  ⎿  ", "2"), rest: "     ", sgr: "0")
        lines.append(Line([("2", "      212   "), ("0;41", "-    let cols = grid.columns;")]))
        lines.append(Line([("2", "      212   "), ("0;42", "+    let cols = grid.columns.min(MAX_SURFACE_COLUMNS);")]))
        lines.append(Line([("2", "      213   "), ("0;42", "+    debug_assert!(cols > 0, \"a grid with no columns pans nowhere\");")]))
        lines.append(Line(""))
        lines += wrap("Bash(cargo test -p link viewport -- --nocapture)", width: width, first: Line("⏺ ", "32"), rest: "  ", sgr: "1")
        lines += wrap("running 14 tests ... test result: ok. 14 passed; 0 failed; 0 ignored; finished in 0.03s", width: width, first: Line("  ⎿  ", "2"), rest: "     ")
        lines.append(Line(""))
        let input = boxed([Line([("0", "> ")])], width: width, sgr: "2")
        lines += input
        var status = Line("  ? for shortcuts", "2")
        let accept = "⏵⏵ accept edits on"
        if width - status.width - accept.count - 2 > 2 {
            status.add(String(repeating: " ", count: width - status.width - accept.count - 2))
            status.add(accept, "38;5;141")
        }
        lines.append(status)
        return lines
    }

    private static func render(_ lines: [Line], width: Int, rows: Int) -> Frame {
        // Rows each line takes at this width (the terminal wraps longer ones).
        let total = lines.reduce(0) { $0 + max(1, ($1.width + width - 1) / width) }
        var text = "\u{1B}c"
        text += lines.map(\.rendered).joined(separator: "\r\n")
        // The cursor goes back into the input box, after "│ > ".
        text += "\(esc)2A\r\(esc)4C"
        let cursorRow = total - 3 - max(0, total - rows)
        return Frame(bytes: Data(text.utf8), focus: (max(0, cursorRow), 4))
    }

    // MARK: htop (alternate screen)

    private static func meter(_ label: String, _ fraction: Double, _ value: String, width: Int, bar: String = "32") -> Line {
        let inner = max(4, width - label.count - 2)
        let filled = min(inner - value.count, Int(Double(inner) * fraction))
        var line = Line(label, "1;36")
        line.add("[", "1")
        line.add(String(repeating: "|", count: max(0, filled)), bar)
        line.add(String(repeating: " ", count: max(0, inner - max(0, filled) - value.count)))
        line.add(value, "2")
        line.add("]", "1")
        return line
    }

    private static func htop(columns width: Int, rows: Int) -> Frame {
        let cpus: [Double] = [0.62, 0.18, 0.91, 0.33, 0.07, 0.45, 0.12, 0.78]
        let twoColumns = width >= 60
        let half = twoColumns ? (width - 1) / 2 : width
        var left: [Line] = [], right: [Line] = []
        for (index, load) in cpus.enumerated() {
            let line = meter(String(format: "%3d", index), load, String(format: "%.1f%%", load * 100), width: half)
            if twoColumns, index >= cpus.count / 2 { right.append(line) } else { left.append(line) }
        }
        left.append(meter("Mem", 0.35, "11.2G/32.0G", width: half, bar: "32"))
        left.append(meter("Swp", 0, "0K/0K", width: half, bar: "31"))
        let info = [
            Line([("1;36", "  Tasks: "), ("1", "412"), ("0", ", 1873 thr; "), ("1;32", "3"), ("0", " running")]),
            Line([("1;36", "  Load average: "), ("1", "2.31 "), ("1;36", "2.04 "), ("0", "1.88")]),
            Line([("1;36", "  Uptime: "), ("1", "3 days, 04:12:55")]),
        ]
        if twoColumns { right += info } else { left += info }
        var lines: [Line] = []
        for index in 0..<max(left.count, right.count) {
            var line = index < left.count ? left[index].padded(to: half) : Line(String(repeating: " ", count: half))
            if twoColumns, index < right.count {
                line.add(" ")
                line.spans += right[index].spans
            }
            lines.append(line)
        }
        lines.append(Line(""))
        lines.append(Line("    PID USER       PRI  NI  VIRT   RES   SHR S  CPU% MEM%   TIME+  Command", "30;42").padded(to: width, "30;42"))
        let selectedRow = lines.count
        let processes: [(Int, String, String, String, Double, Double, String, String)] = [
            (48213, "leo", "1.2G", "412M", 91.4, 1.3, "12:04.11", "cargo build --release --target aarch64-apple-darwin -p link"),
            (48190, "leo", "842M", "301M", 62.0, 0.9, "8:41.02", "rustc --crate-name link --edition=2021 crates/link/src/lib.rs --error-format=json"),
            (1022, "leo", "2.4G", "688M", 33.1, 2.1, "1h02:13", "node /Users/leo/.local/bin/claude --resume"),
            (991, "leo", "1.9G", "540M", 18.2, 1.6, "48:20.77", "codex --sandbox workspace-write --ask-for-approval on-request"),
            (412, "root", "310M", "88M", 7.4, 0.3, "3h11:09", "/usr/sbin/postgres -D /var/db/postgres -c shared_buffers=256MB"),
            (733, "leo", "120M", "41M", 4.5, 0.1, "22:51.43", "zsh -l"),
            (2210, "leo", "96M", "30M", 1.2, 0.1, "0:44.18", "ssh -N -L 5432:localhost:5432 db.internal"),
            (88, "root", "64M", "12M", 0.7, 0.0, "1h40:02", "/usr/libexec/logd"),
            (2301, "leo", "48M", "9M", 0.3, 0.0, "0:02.91", "tail -f target/debug/build.log"),
            (1, "root", "40M", "11M", 0.0, 0.0, "9h12:44", "/sbin/launchd"),
        ]
        let process = { (index: Int) -> Line in
            let p = processes[index % processes.count]
            let pid = p.0 + (index / processes.count) * 7
            func pad(_ value: String, _ count: Int, left: Bool = true) -> String {
                let fill = String(repeating: " ", count: max(0, count - value.count))
                return left ? fill + value : value + fill
            }
            let priority = 20 + (index % 3 == 0 ? 11 : 0)
            let text = [pad(String(pid), 7), pad(p.1, 9, left: false), pad(String(priority), 3), pad("0", 3), pad(p.2, 5), pad(p.3, 5),
                        pad("21M", 5), index == 0 ? "R" : "S", pad(String(format: "%.1f", p.4), 5), pad(String(format: "%.1f", p.5), 4),
                        pad(p.6, 9)].joined(separator: " ") + "  " + p.7
            return index == 0 ? Line(text, "30;46").padded(to: width, "30;46") : Line(text, "0")
        }
        var index = 0
        while lines.count < rows - 1 {
            lines.append(process(index))
            index += 1
        }
        var keys = Line()
        for (key, label) in [("F1", "Help  "), ("F2", "Setup "), ("F3", "Search"), ("F4", "Filter"), ("F5", "Tree  "),
                             ("F6", "SortBy"), ("F7", "Nice -"), ("F8", "Nice +"), ("F9", "Kill  "), ("F10", "Quit  ")] {
            keys.add(key, "0")
            keys.add(label, "30;46")
        }
        lines.append(keys)
        var text = "\u{1B}c\(esc)?1049h\(esc)?25l\(esc)H\(esc)2J"
        for (row, line) in lines.prefix(rows).enumerated() {
            text += "\(esc)\(row + 1);1H" + line.truncated(to: width).rendered
        }
        return Frame(bytes: Data(text.utf8), focus: (selectedRow, 0))
    }
}
#endif
