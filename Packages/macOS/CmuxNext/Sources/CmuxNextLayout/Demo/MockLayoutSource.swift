public import AppKit
import CmuxNextDesign

/// Stands in for the daemon: owns a tree, applies intents to it, and pushes
/// snapshots back into a `LayoutModel`. Lets the module be demoed alone.
public final class MockLayoutSource {
    public let model: LayoutModel
    public private(set) var screens: [LayoutScreen]
    public private(set) var intentLog: [LayoutIntent] = []
    private var nextID = 100

    public init(screens: [LayoutScreen] = MockLayoutSource.sampleScreens()) {
        self.screens = screens
        self.model = LayoutModel(screens: screens)
        model.intentHandler = { [weak self] intent in self?.handle(intent) }
    }

    /// A columns screen with three columns and a plain split screen.
    public static func sampleScreens() -> [LayoutScreen] {
        [
            LayoutScreen(id: "s1", name: "Columns", layout: .columns([
                LayoutColumn(id: "c1", width: 2.0 / 3.0, root: .split("x1", axis: .vertical, ratio: 0.6, a: .leaf("p1"), b: .leaf("p2"))),
                LayoutColumn(id: "c2", width: 0.5, root: .leaf("p3")),
                LayoutColumn(id: "c3", width: 1.0 / 3.0, root: .split("x2", axis: .vertical, ratio: 0.5, a: .leaf("p4"), b: .leaf("p5"))),
            ])),
            LayoutScreen(id: "s2", name: "Splits", layout: .splits(
                .split("x3", axis: .horizontal, ratio: 0.5,
                       a: .leaf("p6"),
                       b: .split("x4", axis: .vertical, ratio: 0.5, a: .leaf("p7"), b: .leaf("p8")))
            )),
        ]
    }

    private func makeID(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)\(nextID)"
    }

    private func push() {
        model.apply(screens: screens)
    }

    public func handle(_ intent: LayoutIntent) {
        intentLog.append(intent)
        if intentLog.count > 200 { intentLog.removeFirst(intentLog.count - 200) }
        switch intent {
        case .focus, .scrollTo, .selectScreen:
            return
        case let .setSplitRatio(split, ratio, _, _):
            mutateLayouts { $0.settingRatio(ratio, for: split) }
        case let .setColumnWidth(column, _, width, _, _):
            mutateLayouts { $0.settingWidth(width, for: column) }
        case let .newColumn(after, width):
            let pane = PaneID(makeID("p"))
            insertColumn(LayoutColumn(id: ColumnID(makeID("c")), width: width, root: .leaf(pane)), afterColumnContaining: after)
            push()
            model.focus(pane)
            return
        case let .split(pane, axis):
            let new = PaneID(makeID("p"))
            split(pane, axis: axis, newPane: new, newFirst: false)
            push()
            model.focus(new)
            return
        case let .dropTab(_, target):
            let new = PaneID(makeID("p"))
            switch target {
            case let .pane(pane, zone):
                guard let axis = zone.splitAxis else { return }
                split(pane, axis: axis, newPane: new, newFirst: zone == .left || zone == .top)
            case let .newColumn(screen, after):
                insertColumn(LayoutColumn(id: ColumnID(makeID("c")), root: .leaf(new)), inScreen: screen, after: after)
            }
            push()
            model.focus(new)
            return
        }
        push()
    }

    /// Removes a pane, collapsing its parent split and empty columns.
    public func closePane(_ pane: PaneID) {
        for index in screens.indices {
            switch screens[index].layout {
            case let .splits(root):
                if let collapsed = Self.removing(pane, from: root) { screens[index].layout = .splits(collapsed) }
            case let .columns(columns):
                screens[index].layout = .columns(columns.compactMap { column in
                    guard column.root.contains(pane) else { return column }
                    guard let root = Self.removing(pane, from: column.root) else { return nil }
                    return LayoutColumn(id: column.id, width: column.width, root: root)
                })
            }
        }
        push()
    }

    private func mutateLayouts(_ transform: (ScreenLayout) -> ScreenLayout) {
        for index in screens.indices { screens[index].layout = transform(screens[index].layout) }
    }

    private func split(_ pane: PaneID, axis: SplitAxis, newPane: PaneID, newFirst: Bool) {
        let splitID = SplitID(makeID("x"))
        func replace(_ node: SplitNode) -> SplitNode {
            switch node {
            case let .leaf(leaf) where leaf == pane:
                let new = SplitNode.leaf(newPane)
                return .split(splitID, axis: axis, ratio: 0.5, a: newFirst ? new : node, b: newFirst ? node : new)
            case .leaf:
                return node
            case let .split(id, nodeAxis, ratio, a, b):
                return .split(id, axis: nodeAxis, ratio: ratio, a: replace(a), b: replace(b))
            }
        }
        mutateLayouts { layout in
            switch layout {
            case let .splits(root): .splits(replace(root))
            case let .columns(columns): .columns(columns.map { LayoutColumn(id: $0.id, width: $0.width, root: replace($0.root)) })
            }
        }
    }

    private func insertColumn(_ column: LayoutColumn, afterColumnContaining pane: PaneID) {
        guard let index = screens.firstIndex(where: { $0.layout.contains(pane) }) else { return }
        var columns: [LayoutColumn]
        switch screens[index].layout {
        case let .splits(root):
            // First column request turns a split screen into a columns screen.
            columns = [LayoutColumn(id: ColumnID(makeID("c")), width: 1.0, root: root)]
        case let .columns(existing):
            columns = existing
        }
        let position = (columns.firstIndex { $0.root.contains(pane) } ?? columns.count - 1) + 1
        columns.insert(column, at: position)
        screens[index].layout = .columns(columns)
    }

    private func insertColumn(_ column: LayoutColumn, inScreen screen: ScreenID, after: ColumnID?) {
        guard let index = screens.firstIndex(where: { $0.id == screen }) else { return }
        var columns = screens[index].layout.columns
        let position = after.flatMap { id in columns.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        columns.insert(column, at: position)
        screens[index].layout = .columns(columns)
    }

    static func removing(_ pane: PaneID, from node: SplitNode) -> SplitNode? {
        switch node {
        case let .leaf(leaf):
            return leaf == pane ? nil : node
        case let .split(id, axis, ratio, a, b):
            let newA = removing(pane, from: a)
            let newB = removing(pane, from: b)
            switch (newA, newB) {
            case let (x?, y?): return .split(id, axis: axis, ratio: ratio, a: x, b: y)
            case let (x?, nil): return x
            case let (nil, y?): return y
            case (nil, nil): return nil
            }
        }
    }
}

/// Colored placeholder panes for the demo.
public final class MockPaneContentProvider: LayoutPaneContentProvider {
    public private(set) var presence: [PaneID: PanePresence] = [:]

    public init() {}

    public func makeContentView(for pane: PaneID) -> NSView {
        MockPaneView(pane: pane)
    }

    public func panePresenceDidChange(_ pane: PaneID, presence: PanePresence) {
        self.presence[pane] = presence
    }
}

private final class MockPaneView: NSView {
    private let hue: CGFloat
    private let label: NSTextField

    init(pane: PaneID) {
        var hash: UInt64 = 1469598103934665603
        for byte in pane.rawValue.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        hue = CGFloat(hash % 360) / 360
        label = NSTextField(labelWithString: String(localized: "layout.demo.paneTitle", defaultValue: "Pane \(pane.rawValue)", bundle: .module))
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(white: 1, alpha: 0.85)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
        ])
        updateLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor(hue: hue, saturation: 0.35, brightness: 0.42, alpha: 1).cgColor
    }
}
