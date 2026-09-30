public import AppKit
import CmuxNextDesign

/// A standalone window showing the layout engine with colored mock panes.
///
/// Keys: Cmd-Arrows focus, Cmd-N new column, Cmd-D split right,
/// Cmd-Shift-D split down, Cmd-R / Cmd-Shift-R cycle column width presets,
/// Cmd-W close pane, Cmd-1...9 screens,
/// Cmd-I toggle inactive dimming, Cmd-E toggle centered focus.
/// Drag the "Tab" chip onto panes or column gaps.
public final class LayoutDemoController: NSObject {
    public let source: MockLayoutSource
    public let provider = MockPaneContentProvider()
    public let window: NSWindow
    public let rootView: LayoutRootView
    private var keyMonitor: Any?

    public override init() {
        source = MockLayoutSource()
        rootView = LayoutRootView(model: source.model, contentProvider: provider)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = String(localized: "layout.demo.windowTitle", defaultValue: "Layout Demo", bundle: .module)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Palette.windowBackground.cgColor
        rootView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rootView)
        let chip = DemoTabChip()
        chip.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chip)
        NSLayoutConstraint.activate([
            rootView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rootView.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            rootView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            chip.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Metrics.space5),
            chip.topAnchor.constraint(equalTo: container.topAnchor, constant: Metrics.space4),
        ])
        window.contentView = container
        installKeys()
    }

    isolated deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    public func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        let shift = flags.contains(.shift)
        let model = source.model
        switch event.keyCode {
        case 123: rootView.moveFocus(.left)
        case 124: rootView.moveFocus(.right)
        case 125: rootView.moveFocus(.down)
        case 126: rootView.moveFocus(.up)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "n": model.newColumn()
            case "d": model.splitFocusedPane(axis: shift ? .vertical : .horizontal)
            case "r": model.cycleColumnWidthPreset(forward: !shift)
            case "w": if let pane = model.focusedPane { source.closePane(pane) }
            case "i": model.dimsInactivePanes.toggle()
            case "e":
                let modes = CenterFocusedColumn.allCases
                model.centerFocusedColumnOverride = modes[((modes.firstIndex(of: model.centerFocusedColumn) ?? 0) + 1) % modes.count]
            case let digit? where Int(digit).map({ (1...9).contains($0) }) == true:
                let index = Int(digit)! - 1
                if model.screens.indices.contains(index) { model.selectScreen(model.screens[index].id) }
            default: return false
            }
        }
        return true
    }
}

/// A draggable stand-in for a tab from the tab strip.
private final class DemoTabChip: NSView, NSDraggingSource {
    private var counter = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Metrics.itemCornerRadius
        layer?.backgroundColor = Palette.selectionFill.cgColor
        let label = NSTextField(labelWithString: String(localized: "layout.demo.tabChip", defaultValue: "Tab", bundle: .module))
        label.font = Typography.bodyEmphasized
        label.textColor = Palette.textPrimary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Metrics.tabHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDragged(with event: NSEvent) {
        counter += 1
        let item = NSPasteboardItem()
        item.setString("demo-tab-\(counter)", forType: LayoutTabDrag.pasteboardType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size, flipped: false) { [weak self] rect in
            guard let self else { return false }
            self.layer?.render(in: NSGraphicsContext.current!.cgContext)
            return true
        }
        dragItem.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }
}
