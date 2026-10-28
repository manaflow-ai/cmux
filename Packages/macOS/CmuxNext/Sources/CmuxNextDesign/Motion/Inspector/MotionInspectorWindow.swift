public import AppKit
import CmuxNextCompat
import CmuxNextDesignTokens
public import CmuxNextWakeups

/// Debug > Debug Windows > Motion Inspector (DEV and NIGHTLY; `debug.motion` `window` in any build with the
/// debug socket): the ``MotionInspector``'s controls and its live list of animations.
///
/// The top row plays motion at 1x, 2x, 5x, 10x or paused, and steps one display frame back or forward;
/// the second keeps only the checked categories moving. The table lists every animation since the
/// inspection started, running ones first: owner (call site and type), kind, property, from and to,
/// curve, start and expected end (animation milliseconds), frames, dropped frames, main-thread
/// milliseconds per frame, and where it runs. The footer shows the inspector's own cost and the gate
/// bypasses a scan finds.
///
/// Opening it starts the inspection; closing it stops it, so nothing of the inspector runs once it is closed.
/// It follows the model with one `VisibleObservation` on its window's visibility node: one draw per flush
/// however many records changed, none while the window is hidden or occluded; its draw time counts in the
/// inspector's overhead.
public final class MotionInspectorWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// The model the window shows and drives (the composition root makes one of each and injects them).
    public let inspector: MotionInspector
    private var window: NSWindow?
    private var scaleControl: NSSegmentedControl?
    private var categoryBoxes: [MotionCategory: NSButton] = [:]
    private var kindControl: NSPopUpButton?
    private var table: NSTableView?
    private var footer: NSTextField?
    private var findingsLabel: NSTextField?
    private var rows: [MotionInspectorRecord] = []

    private let work: MainWorkScheduler
    private var observation: VisibleObservation<Snapshot>?

    /// What one draw shows: the model's observed state.
    private struct Snapshot: Equatable {
        var revision: Int
        var scale: MotionTimeScale
        var kept: Set<MotionCategory>?
        var kind: MotionInspector.FilterKind?
        var records: [MotionInspectorRecord]
        var running: Int
        var total: Int
        var findings: [MotionInspectorFinding]
    }

    /// - Parameters:
    ///   - inspector: The model the window shows and drives.
    ///   - work: The app's main-thread scheduler the window's observation flushes on.
    public init(inspector: MotionInspector, work: MainWorkScheduler) {
        self.inspector = inspector
        self.work = work
    }

    /// Whether the window is on screen.
    public var isShown: Bool { window?.isVisible == true }

    /// Shows the window (starting the inspection), or closes it (stopping the inspection).
    public func toggle(over parent: NSWindow? = nil) {
        isShown ? close() : show(over: parent)
    }

    /// Shows the window and starts the inspection. `focus` (a person's menu or palette choice) makes it key;
    /// a script's open (`debug.motion` `window`) orders it in front without taking the keys or activating cmux.
    public func show(over parent: NSWindow? = nil, focus: Bool = true) {
        inspector.start()
        let window = self.window ?? makeWindow()
        self.window = window
        if observation == nil {
            observation = VisibleObservation(WindowVisibilitySource.of(window).node, owner: "MotionInspectorWindow", on: work) { [inspector] in
                Snapshot(revision: inspector.revision, scale: inspector.timeScale, kept: inspector.keptCategories, kind: inspector.filterKind,
                         records: inspector.shownRecords, running: inspector.records.filter(\.isRunning).count,
                         total: inspector.records.count, findings: inspector.findings)
            } apply: { [weak self] snapshot in
                self?.draw(snapshot)
            }
        }
        if focus {
            WindowPlacement.present(window, parent: parent)
        } else {
            if !window.isVisible, let frame = parent?.frame {
                window.setFrameTopLeftPoint(NSPoint(x: frame.minX + 24, y: frame.maxY - 24))
            }
            window.orderFrontRegardless()
        }
    }

    /// Closes the window and stops the inspection.
    public func close() {
        window?.orderOut(nil)
        observation = nil
        inspector.stop()
    }

    public func windowWillClose(_ notification: Notification) {
        observation = nil
        inspector.stop()
    }

    // MARK: Rendering

    private func draw(_ snapshot: Snapshot) {
        let began = CACurrentMediaTime()
        scaleControl?.selectedSegment = Self.scales.firstIndex(of: snapshot.scale) ?? 0
        for (category, box) in categoryBoxes { box.state = snapshot.kept?.contains(category) ?? true ? .on : .off }
        kindControl?.selectItem(at: snapshot.kind.flatMap { MotionInspector.FilterKind.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        rows = snapshot.records.sorted { ($0.isRunning ? 0 : 1, -$0.start) < ($1.isRunning ? 0 : 1, -$1.start) }
        table?.reloadData()
        let overhead = inspector.overhead
        footer?.stringValue = Strings.footer(running: snapshot.running, total: snapshot.total,
                                             p50: overhead.framePercentile(0.5), p95: overhead.framePercentile(0.95),
                                             start: overhead.noteMeanMs)
        findingsLabel?.stringValue = snapshot.findings.isEmpty ? Strings.noFindings(scanned: overhead.lastScanMs != nil)
            : snapshot.findings.prefix(8).map { "\($0.ownerType)  \($0.property)  \($0.animationClass)  \(Int(($0.seconds * 1000).rounded())) ms"
                + ($0.appKitOwned ? "  (AppKit)" : "") }.joined(separator: "\n")
        // Its own draw is part of what the inspector costs (``MotionInspector/overhead`` is not observed: no redraw).
        if inspector.isInspecting { inspector.overhead.addToLastFrame((CACurrentMediaTime() - began) * 1000) }
    }

    // MARK: Controls

    private static let scales: [MotionTimeScale] = [.x1, .x2, .x5, .x10, .paused]

    @objc private func scaleChanged(_ sender: NSSegmentedControl) {
        guard Self.scales.indices.contains(sender.selectedSegment) else { return }
        inspector.setTimeScale(Self.scales[sender.selectedSegment])
    }

    @objc private func stepBack(_ sender: Any?) { inspector.step(frames: -1) }
    @objc private func stepForward(_ sender: Any?) { inspector.step(frames: 1) }
    @objc private func scan(_ sender: Any?) { inspector.scan() }

    @objc private func kindChosen(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        let kinds = MotionInspector.FilterKind.allCases
        if kinds.indices.contains(index) { inspector.setFilter(kind: kinds[index]) } else { inspector.setFilter(keeping: nil) }
    }

    @objc private func categoryToggled(_ sender: NSButton) {
        let kept = Set(categoryBoxes.filter { $0.value.state == .on }.map(\.key))
        inspector.setFilter(keeping: kept)
    }

    // MARK: Table

    private enum Column: String, CaseIterable {
        case owner, kind, property, fromTo, curve, start, end, frames, dropped, mainMs, runs

        var width: CGFloat {
            switch self {
            case .owner: 260
            case .kind, .curve: 150
            case .property, .fromTo: 110
            case .start, .end, .frames, .dropped, .mainMs: 64
            case .runs: 90
            }
        }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let column = Column(rawValue: id), rows.indices.contains(row) else { return nil }
        let cellID = NSUserInterfaceItemIdentifier("cell." + id)
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = cellID
            field.font = Typography.system(.monospacedDigit, size: TypeScale.caption)
            field.lineBreakMode = .byTruncatingMiddle
            return field
        }()
        let record = rows[row]
        cell.stringValue = Self.text(column, record)
        cell.textColor = !record.gated || record.droppedFrames > 0 || record.runs != .renderServer && column == .runs ? Palette.danger
            : record.isRunning ? Palette.textPrimary : Palette.textTertiary
        cell.toolTip = column == .owner ? record.owner : nil
        return cell
    }

    /// Diagnostic tokens (call sites, key paths, curve names, numbers) are not prose: not localized.
    private static func text(_ column: Column, _ record: MotionInspectorRecord) -> String {
        func ms(_ seconds: Double?) -> String { seconds.map { String(format: "%.0f", $0 * 1000) } ?? "-" }
        switch column {
        case .owner: return record.owner
        case .kind:
            let kind = record.category.map { "\($0.rawValue) \(record.kind)" } ?? record.kind
            return record.layers > 1 ? "\(kind) ×\(record.layers)" : kind
        case .property: return record.property
        case .fromTo: return record.from == nil && record.to == nil ? "-" : "\(record.from ?? "?") → \(record.to ?? "?")"
        case .curve:
            switch record.curve {
            case .spring(let response, let damping, let perceived):
                return String(format: "spring r%.0f d%.2f ~%.0f", response * 1000, damping, perceived * 1000)
            case .timed(let seconds, let name): return String(format: "%@ %.0f", name, seconds * 1000)
            case .loop(let period): return String(format: "loop %.0f", period * 1000)
            case .stepped: return "stepped"
            }
        case .start: return ms(record.start)
        case .end: return ms(record.ended ?? record.expectedEnd)
        case .frames: return "\(record.frames)"
        case .dropped: return "\(record.droppedFrames)"
        case .mainMs: return record.mainMeanMs.map { String(format: "%.2f", $0) } ?? (record.runs == .appKit ? "appkit" : "0")
        case .runs: return record.runs.rawValue
        }
    }

    // MARK: Building

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 520),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = Strings.title
        window.isReleasedWhenClosed = false
        window.isRestorable = false  // AppKit state restoration is off for every cmux window (p08-startup-087)
        window.delegate = self
        window.animationBehavior = .none

        let scale = NSSegmentedControl(labels: Self.scales.map(Strings.scaleLabel), trackingMode: .selectOne,
                                       target: self, action: #selector(scaleChanged(_:)))
        scaleControl = scale
        let back = NSButton(title: Strings.stepBack, target: self, action: #selector(stepBack(_:)))
        let forward = NSButton(title: Strings.stepForward, target: self, action: #selector(stepForward(_:)))
        let scanButton = NSButton(title: Strings.scan, target: self, action: #selector(scan(_:)))
        let controls = NSStackView(views: [scale, back, forward, NSView(), scanButton])
        controls.spacing = 8

        var boxes: [NSView] = [NSTextField(labelWithString: Strings.filter)]
        for category in MotionCategory.allCases {
            let box = NSButton(checkboxWithTitle: category.rawValue, target: self, action: #selector(categoryToggled(_:)))
            box.font = Typography.system(size: TypeScale.caption)
            categoryBoxes[category] = box
            boxes.append(box)
        }
        let kinds = NSPopUpButton(frame: .zero, pullsDown: false)
        // Kind names are the socket's and the CLI's ids (`--kind sidebarRows`): diagnostic tokens, not prose.
        kinds.addItems(withTitles: [Strings.allKinds] + MotionInspector.FilterKind.allCases.map(\.rawValue))
        kinds.target = self
        kinds.action = #selector(kindChosen(_:))
        kindControl = kinds
        boxes.insert(kinds, at: 1)
        let filter = NSStackView(views: boxes)
        filter.spacing = 6

        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = TypeScale.captionLineHeight + 4
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = Strings.column(column.rawValue)
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        self.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true

        let footer = NSTextField(labelWithString: "")
        footer.font = Typography.system(.monospacedDigit, size: TypeScale.caption)
        footer.textColor = Palette.textSecondary
        self.footer = footer
        let findings = NSTextField(wrappingLabelWithString: "")
        findings.font = Typography.system(.monospaced, size: TypeScale.caption)
        findings.textColor = Palette.textSecondary
        findingsLabel = findings

        let stack = NSStackView(views: [controls, filter, scroll, footer, findings])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -12),
            controls.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -12),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = content
        return window
    }

    // MARK: Strings (MotionInspector.xcstrings)

    private enum Strings {
        static var title: String {
            String(localized: "motionInspector.title", defaultValue: "Motion Inspector", table: "MotionInspector", bundle: .module)
        }
        static var stepBack: String {
            String(localized: "motionInspector.stepBack", defaultValue: "Frame Back", table: "MotionInspector", bundle: .module)
        }
        static var stepForward: String {
            String(localized: "motionInspector.stepForward", defaultValue: "Frame Forward", table: "MotionInspector", bundle: .module)
        }
        static var scan: String {
            String(localized: "motionInspector.scan", defaultValue: "Find Ungated Animations", table: "MotionInspector", bundle: .module)
        }
        static var filter: String {
            String(localized: "motionInspector.filter", defaultValue: "Animate only:", table: "MotionInspector", bundle: .module)
        }
        static var allKinds: String {
            String(localized: "motionInspector.kind.all", defaultValue: "All kinds", table: "MotionInspector", bundle: .module)
        }
        static var paused: String {
            String(localized: "motionInspector.paused", defaultValue: "Paused", table: "MotionInspector", bundle: .module)
        }

        static func scaleLabel(_ scale: MotionTimeScale) -> String {
            scale == .paused ? paused : String(format: "%gx", scale.slowdown)  // a multiplier, not prose
        }

        static func noFindings(scanned: Bool) -> String {
            scanned ? String(localized: "motionInspector.findings.none", defaultValue: "No ungated animation on screen.",
                             table: "MotionInspector", bundle: .module)
                : String(localized: "motionInspector.findings.notScanned",
                         defaultValue: "Not scanned yet: start the animation, then find ungated animations.",
                         table: "MotionInspector", bundle: .module)
        }

        static func footer(running: Int, total: Int, p50: Double, p95: Double, start: Double) -> String {
            String(format: String(localized: "motionInspector.footer",
                                  defaultValue: "%1$d running of %2$d. Inspector cost per frame: p50 %3$.3f ms, p95 %4$.3f ms; per start %5$.3f ms.",
                                  table: "MotionInspector", bundle: .module),
                   running, total, p50, p95, start)
        }

        static func column(_ id: String) -> String {
            switch id {
            case "owner": String(localized: "motionInspector.column.owner", defaultValue: "Owner", table: "MotionInspector", bundle: .module)
            case "kind": String(localized: "motionInspector.column.kind", defaultValue: "Kind", table: "MotionInspector", bundle: .module)
            case "property": String(localized: "motionInspector.column.property", defaultValue: "Property", table: "MotionInspector", bundle: .module)
            case "fromTo": String(localized: "motionInspector.column.fromTo", defaultValue: "From → To", table: "MotionInspector", bundle: .module)
            case "curve": String(localized: "motionInspector.column.curve", defaultValue: "Curve (ms)", table: "MotionInspector", bundle: .module)
            case "start": String(localized: "motionInspector.column.start", defaultValue: "Start", table: "MotionInspector", bundle: .module)
            case "end": String(localized: "motionInspector.column.end", defaultValue: "End", table: "MotionInspector", bundle: .module)
            case "frames": String(localized: "motionInspector.column.frames", defaultValue: "Frames", table: "MotionInspector", bundle: .module)
            case "dropped": String(localized: "motionInspector.column.dropped", defaultValue: "Dropped", table: "MotionInspector", bundle: .module)
            case "mainMs": String(localized: "motionInspector.column.mainMs", defaultValue: "Main ms", table: "MotionInspector", bundle: .module)
            default: String(localized: "motionInspector.column.runs", defaultValue: "Runs on", table: "MotionInspector", bundle: .module)
            }
        }
    }
}
