import AppKit
import CmuxNextDesign
import CmuxNextDevices

/// How much work Your Devices does, for count tests: a one-device change makes one row, a scroll step
/// makes only the rows it reveals, and rows alive stay near one viewport whatever the list's length.
struct MacScreenDeviceRowCounts: Equatable {
    /// Row views alive now.
    var alive = 0
    /// Row views made (a row new near the viewport, or one whose values changed).
    var made = 0
    /// Row frames set (a row placed, moved or resized).
    var framed = 0
    /// Realize passes (a list update, a layout, a scroll).
    var realizes = 0
}

/// The page's scroll view, telling its owner of every scroll (the clip view's bounds moved).
@MainActor
final class MacScreenPageScrollView: OverlayScrollView {
    var onScroll: (() -> Void)?

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        onScroll?()
    }
}

/// One row of Your Devices, as values: the list makes a view for it only while it is near the viewport.
enum MacScreenDeviceRow: Equatable {
    /// A device in the quiet looks, in its state.
    case quiet(MacScreenHomeSnapshot.Device, MacScreenHomeView.RowState)
    /// A device in the classic look.
    case classic(MacScreenHomeSnapshot.Device)
    /// The quiet look's Offline (N) row.
    case offlineGroup(count: Int, expanded: Bool)
    /// The online-only look's "N offline".
    case offlineCount(Int)

    var id: String {
        switch self {
        case let .quiet(device, _), let .classic(device): "device:\(device.id)"
        case .offlineGroup: "offlineGroup"
        case .offlineCount: "offlineCount"
        }
    }

    /// Rows of one kind are one height until measured.
    var kind: String {
        switch self {
        case let .quiet(_, state): "quiet.\(state)"
        case let .classic(device): "classic.\(device.access.scope == .ask)"
        case .offlineGroup: "offlineGroup"
        case .offlineCount: "offlineCount"
        }
    }
}

/// Your Devices' rows, windowed: views exist only for the rows in the scroll view's viewport and one
/// viewport on each side; the rest are a height. A row whose values did not change keeps its view
/// (no remake, no new frame); a scroll step makes only the rows it brings near the viewport.
@MainActor
final class MacScreenDeviceRows: NSView {
    /// Viewports of rows kept on each side of the one in view.
    static let overscan: CGFloat = 1
    /// What a row is assumed to be before a row of its kind was measured.
    static let estimatedHeight: CGFloat = 44
    /// The height realized while the page is not in a window (or has no size): the first screenful.
    static let unplacedHeight: CGFloat = 800

    private struct Cell {
        var row: MacScreenDeviceRow
        let container: NSView
        let view: NSView
        var separator: NSView?
    }

    private let make: (MacScreenDeviceRow) -> NSView
    private let makeSeparator: () -> NSView
    private let paint: (NSView) -> Void
    private(set) var rows: [MacScreenDeviceRow] = []
    private var separators = false
    private var index: [String: Int] = [:]
    private var cells: [String: Cell] = [:]
    /// `offsets[i]`: the top of row `i`; the last entry is the list's height.
    private var offsets: [CGFloat] = [0]
    private var measured: [String: CGFloat] = [:]
    private var kindHeights: [String: CGFloat] = [:]
    private(set) var counts = MacScreenDeviceRowCounts()
    /// The list's height changed: the page frames its document again.
    var onHeightChange: (() -> Void)?

    init(make: @escaping (MacScreenDeviceRow) -> NSView, separator: @escaping () -> NSView, paint: @escaping (NSView) -> Void) {
        self.make = make
        makeSeparator = separator
        self.paint = paint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: offsets.last ?? 0) }

    /// Shows `rows`: rows whose values and hairline did not change keep their views.
    func update(_ rows: [MacScreenDeviceRow], separators: Bool) {
        let old = index
        let oldRows = self.rows
        self.rows = rows
        self.separators = separators
        index = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in rows {
            if let at = old[row.id], oldRows[at] == row { continue }
            measured[row.id] = nil
        }
        for (id, cell) in cells where index[id].map({ rows[$0] != cell.row }) ?? true { unmount(id) }
        rebuildOffsets()
        needsLayout = true
        realize()
    }

    override func layout() {
        super.layout()
        realize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        realize()
    }

    // MARK: Windowing

    private func height(of row: MacScreenDeviceRow) -> CGFloat {
        measured[row.id] ?? kindHeights[row.kind] ?? Self.estimatedHeight
    }

    private func hasSeparator(_ at: Int) -> Bool { separators && at < rows.count - 1 }

    /// The tops of every row: a cheap pass over values, on a list change or a newly measured height only.
    private func rebuildOffsets() {
        var offsets = [CGFloat]()
        offsets.reserveCapacity(rows.count + 1)
        var y: CGFloat = 0
        for (at, row) in rows.enumerated() {
            offsets.append(y)
            y += height(of: row) + (hasSeparator(at) ? 1 : 0)
        }
        offsets.append(y)
        let changed = offsets.last != self.offsets.last
        self.offsets = offsets
        if changed {
            invalidateIntrinsicContentSize()
            onHeightChange?()
        }
    }

    /// The row at `y` (the first or last row past the ends).
    private func row(at y: CGFloat) -> Int {
        var low = 0, high = rows.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The part of the list near the viewport, in the list's coordinates.
    private func nearViewport() -> NSRect {
        if let clip = enclosingScrollView?.contentView, clip.bounds.height >= 1 {
            let seen = convert(clip.bounds, from: clip)
            return seen.insetBy(dx: 0, dy: -seen.height * Self.overscan)
        }
        return NSRect(x: 0, y: 0, width: bounds.width, height: Self.unplacedHeight)
    }

    /// Makes the rows near the viewport that have no view, frames the ones that moved, and drops the rest.
    func realize() {
        counts.realizes += 1
        guard !rows.isEmpty else {
            for id in Array(cells.keys) { unmount(id) }
            counts.alive = 0
            return
        }
        var range = 0..<0
        // A newly measured kind moves the rows after it: place again with the measured heights (once per kind).
        for _ in 0..<3 {
            let near = nearViewport()
            range = near.maxY < 0 || near.minY > (offsets.last ?? 0) ? 0..<0 : row(at: near.minY)..<(row(at: near.maxY) + 1)
            var remeasured = false
            for at in range where cells[rows[at].id] == nil {
                let row = rows[at]
                let view = make(row)
                counts.made += 1
                let height = ceil(view.fittingSize.height)
                if abs(height - self.height(of: row)) > 0.5 { remeasured = true }
                measured[row.id] = height
                if kindHeights[row.kind] == nil { kindHeights[row.kind] = height }
                mount(row, view: view)
            }
            if !remeasured { break }
            rebuildOffsets()
        }
        for (id, _) in cells where !(index[id].map(range.contains) ?? false) { unmount(id) }
        place(range)
    }

    private func mount(_ row: MacScreenDeviceRow, view: NSView) {
        let container = MacScreenFlippedView()
        container.translatesAutoresizingMaskIntoConstraints = true
        view.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(view)
        paint(container)
        cells[row.id] = Cell(row: row, container: container, view: view)
    }

    private func unmount(_ id: String) {
        cells.removeValue(forKey: id)?.container.removeFromSuperview()
    }

    /// Frames the rows in `range` in list order (accessibility and the key loop follow it); only the ones that moved.
    private func place(_ range: Range<Int>) {
        var order: [NSView] = []
        let width = bounds.width
        for at in range {
            let row = rows[at]
            guard var cell = cells[row.id] else { continue }
            let rowHeight = height(of: row)
            let lined = hasSeparator(at)
            if lined, cell.separator == nil {
                let line = makeSeparator()
                line.translatesAutoresizingMaskIntoConstraints = true
                paint(line)
                cell.container.addSubview(line)
                cell.separator = line
            } else if !lined, let line = cell.separator {
                line.removeFromSuperview()
                cell.separator = nil
            }
            cells[row.id] = cell
            let frame = NSRect(x: 0, y: offsets[at], width: width, height: rowHeight + (lined ? 1 : 0))
            if cell.container.frame != frame || cell.view.frame.width != width {
                counts.framed += 1
                cell.container.frame = frame
                cell.view.frame = NSRect(x: 0, y: 0, width: width, height: rowHeight)
                cell.separator?.frame = NSRect(x: 50, y: rowHeight, width: max(0, width - 50), height: 1)
            }
            order.append(cell.container)
        }
        if !subviews.elementsEqual(order, by: ===) { subviews = order }
        counts.alive = cells.count
    }
}
