public import AppKit
import CmuxNextDesign

/// Mock data and a standalone window for demoing the strip without the daemon.
public enum TabStripDemo {
    private static var counter = 0

    public static func makeTab(title: String? = nil) -> TabItem {
        counter += 1
        let samples: [(String, String, String)] = [
            ("zsh", "~/fun/cmux", "terminal"),
            ("claude", "~/fun/cmux/Packages", "sparkles"),
            ("npm run dev", "~/fun/cmux/web", "shippingbox"),
            ("vim TabStripView.swift", "~/fun/cmux/Packages/macOS/CmuxNext", "doc.text"),
            ("cmux.com", "https://cmux.com", "globe"),
            ("htop", "~", "gauge.with.dots.needle.33percent"),
            ("git log", "~/fun/cmux", "arrow.triangle.branch"),
        ]
        let sample = samples[counter % samples.count]
        return TabItem(
            id: TabID("demo-\(counter)"),
            title: title ?? sample.0,
            subtitle: sample.1,
            icon: .symbol(sample.2)
        )
    }

    /// A model with a few tabs, one pinned, one busy, one unread.
    public static func makeModel(style: TabStripStyle = .chrome) -> TabStripModel {
        var tabs = (0..<6).map { _ in makeTab() }
        tabs[0].isPinned = true
        tabs[0].icon = .symbol("pin.fill")
        tabs[2].isBusy = true
        tabs[3].isUnread = true
        tabs[4].status = .needsInput
        let model = TabStripModel(tabs: tabs, selectedID: tabs[1].id, style: style)
        model.intentHandler = { [weak model] intent in
            model?.apply(intent) { makeTab() }
        }
        return model
    }

    /// A window with two strips (drag tabs between them) and demo controls.
    public static func makeWindow() -> NSWindow {
        let controller = DemoContentView()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 360),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = Strings.demoWindowTitle
        window.contentView = controller
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

/// Draws fake terminal thumbnails.
public final class MockTabPreviewProvider: TabPreviewProvider {
    public init() {}

    public func previewImage(for tab: TabID, maxPixelSize: CGSize) async -> CGImage? {
        let width = Int(maxPixelSize.width)
        let height = Int(maxPixelSize.height)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var seed = UInt64(abs(tab.rawValue.hashValue))
        let line = CGFloat(height) / 14
        for row in 0..<12 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let length = CGFloat(seed % 70 + 20) / 100 * CGFloat(width - 24)
            let gray = row == 0 ? 0.85 : 0.35 + CGFloat(seed % 40) / 100
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            let y = CGFloat(height) - CGFloat(row + 1) * line - 6
            context.fill(CGRect(x: 12, y: y, width: length, height: line * 0.45))
        }
        return context.makeImage()
    }
}

private final class DemoContentView: NSView {
    private let top = TabStripDemo.makeModel()
    private let bottom = TabStripDemo.makeModel(style: .compact)
    private let provider = MockTabPreviewProvider()
    private let log = NSTextField(labelWithString: "")
    private var strips: [TabStripView] = []
    private var session: DemoDragSession?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Palette.windowBackground.cgColor
        wire(top, other: bottom)
        wire(bottom, other: top)

        let topStrip = TabStripView(model: top, background: .glass)
        let bottomStrip = TabStripView(model: bottom, background: .glass)
        topStrip.dragsWindowFromEmptySpace = false
        bottomStrip.dragsWindowFromEmptySpace = false
        for strip in [topStrip, bottomStrip] { strip.previewProvider = provider }
        strips = [topStrip, bottomStrip]

        let buttons = NSStackView(views: [
            button(Strings.demoAddTab) { [top] in top.send(.newTab(after: top.selectedID)) },
            button(Strings.demoAddMany) { [top] in for _ in 0..<10 { top.send(.newTab(after: nil)) } },
            button(Strings.demoToggleBusy) { [top] in top.mutateSelected { $0.isBusy.toggle() } },
            button(Strings.demoToggleUnread) { [top] in top.mutateSelected { $0.isUnread.toggle() } },
            button(Strings.demoCycleStatus) { [top] in
                top.mutateSelected {
                    switch $0.status {
                    case .none: $0.status = .needsInput
                    case .needsInput: $0.status = .success
                    case .success: $0.status = .failure
                    case .failure: $0.status = .none
                    }
                }
            },
            button(Strings.demoCompact) { [top] in top.style = top.style == .chrome ? .compact : .chrome },
        ])
        buttons.spacing = 8
        log.textColor = Palette.textSecondary
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        for view in [topStrip, bottomStrip, buttons, log] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            topStrip.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            topStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            topStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            topStrip.heightAnchor.constraint(equalToConstant: TabStripView.preferredHeight),
            bottomStrip.topAnchor.constraint(equalTo: topStrip.bottomAnchor, constant: 180),
            bottomStrip.leadingAnchor.constraint(equalTo: topStrip.leadingAnchor),
            bottomStrip.trailingAnchor.constraint(equalTo: topStrip.trailingAnchor),
            bottomStrip.heightAnchor.constraint(equalToConstant: TabStripView.preferredHeight),
            buttons.topAnchor.constraint(equalTo: bottomStrip.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: topStrip.leadingAnchor),
            log.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 10),
            log.leadingAnchor.constraint(equalTo: topStrip.leadingAnchor),
            log.trailingAnchor.constraint(equalTo: topStrip.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func wire(_ model: TabStripModel, other: TabStripModel) {
        model.intentHandler = { [weak self, weak model] intent in
            guard let self, let model else { return }
            self.log.stringValue = Strings.demoLog(String(describing: intent))
            if case .dragBegan(let start) = intent {
                self.session = DemoDragSession(start: start, strips: self.strips) { [weak self] in self?.session = nil }
                return
            }
            model.apply(intent) { TabStripDemo.makeTab() }
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .push
        return button
    }
}

private extension TabStripModel {
    func mutateSelected(_ change: (inout TabItem) -> Void) {
        guard let selectedID, let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        change(&tabs[index])
    }
}

private final class ClosureButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        handler = action
        target = self
        self.action = #selector(fire)
    }

    @objc private func fire() {
        handler?()
    }
}

/// A minimal stand-in for the App's `TabDragSession`: a floating ghost that
/// follows the pointer, phantom gaps in whichever strip is under it, and a
/// local model move on drop. Shows how the strip's drag APIs fit together.
final class DemoDragSession {
    private let start: TabDragStart
    private let strips: [TabStripView]
    private let ghost: NSPanel
    private var monitor: Any?
    private var target: (strip: TabStripView, target: TabStripDropTarget)?
    private let finished: () -> Void

    init(start: TabDragStart, strips: [TabStripView], finished: @escaping () -> Void) {
        self.start = start
        self.strips = strips
        self.finished = finished
        ghost = NSPanel(contentRect: start.screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ghost.isOpaque = false
        ghost.backgroundColor = .clear
        ghost.hasShadow = true
        ghost.ignoresMouseEvents = true
        ghost.level = .floating
        let image = NSImageView()
        if let snapshot = start.snapshot {
            image.image = NSImage(cgImage: snapshot.cgImage, size: start.screenFrame.size)
        }
        image.imageScaling = .scaleAxesIndependently
        ghost.contentView = image
        ghost.alphaValue = 0.92
        ghost.orderFrontRegardless()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            self?.handle(event)
            return event
        }
        move(to: start.screenPoint)
    }

    func move(to point: CGPoint) {
        target = nil
        for strip in strips {
            if let hit = strip.updatePhantom(atScreenPoint: point), target == nil {
                target = (strip, hit)
            } else if target != nil {
                strip.hidePhantom()
            }
        }
        let size = start.screenFrame.size
        let frame = target?.target.ghostFrame
            ?? CGRect(x: point.x - start.grabOffset.x, y: point.y - start.grabOffset.y, width: size.width, height: size.height)
        ghost.setFrame(frame, display: true)
    }

    func drop() {
        defer { end() }
        guard let (strip, hit) = target, let source = strips.first(where: { $0.model.stripID == start.stripID }) else {
            cancel()
            return
        }
        let destination = strip.model
        strip.commitPhantom(tabID: start.tabID)
        if destination === source.model {
            destination.apply(.reorder(start.tabID, from: 0, to: hit.index)) { TabStripDemo.makeTab() }
            destination.selectedID = start.tabID
        } else if var item = source.model.tab(start.tabID) {
            source.model.apply(.close(start.tabID, source: .keyboard)) { TabStripDemo.makeTab() }
            item.isPinned = false
            var ordered = destination.orderedTabs
            ordered.insert(item, at: min(hit.index, ordered.count))
            destination.tabs = ordered
            destination.selectedID = item.id
        }
    }

    func cancel() {
        strips.first { $0.model.stripID == start.stripID }?.restoreDetachedTab(start.tabID)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged: move(to: NSEvent.mouseLocation)
        case .leftMouseUp: drop()
        case .keyDown where event.keyCode == 53:
            cancel()
            end()
        default: break
        }
    }

    private func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for strip in strips { strip.hidePhantom() }
        ghost.orderOut(nil)
        finished()
    }
}
