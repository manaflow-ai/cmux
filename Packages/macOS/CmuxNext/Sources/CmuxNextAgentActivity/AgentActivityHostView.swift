import AppKit
import CmuxNextDesign

/// Hosts the native AppKit Agent activity pane.
public final class AgentActivityHostView: NSView {
    public let model: AgentActivityModel
    public let nativeView: AgentActivityNativeView
    private let source: any AgentActivitySource

    /// Makes a native activity pane for an injected source and model.
    public init(model: AgentActivityModel, source: any AgentActivitySource) {
        self.model = model
        self.source = source
        nativeView = AgentActivityNativeView(model: model, source: source)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        nativeView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nativeView)
        NSLayoutConstraint.activate([
            nativeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            nativeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            nativeView.topAnchor.constraint(equalTo: topAnchor),
            nativeView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        model.observeChanges { [weak nativeView] in nativeView?.reload() }
    }

    /// Compatibility initializer for prototype snapshot callers.
    public convenience init(model: AgentActivityModel, layoutOverride: AgentActivityLayout? = nil) {
        if let layoutOverride { model.layout = layoutOverride }
        self.init(model: model, source: AgentActivityMockSource())
    }

    /// The old prototype page remains bundled for resource compatibility.
    public static var bundledPage: URL? {
        Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "agent-activity")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Exposes the source for composition roots that install a control adapter.
    public var activitySource: any AgentActivitySource { source }
}

/// AppKit renderer for the activity pane. It uses native scroll views and
/// layers, while the model remains the single source of state.
public final class AgentActivityNativeView: NSView {
    private let model: AgentActivityModel
    private let sessionStack = NSStackView()
    private let eventStack = NSStackView()
    private let preview = NSImageView()
    private let filmstrip = AgentActivityThumbnailFilmstrip()
    private let title = NSTextField(labelWithString: AgentActivityStrings.title)
    private let stopAll = NSButton()

    init(model: AgentActivityModel, source: any AgentActivitySource) {
        self.model = model
        super.init(frame: .zero)
        build()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func reload() {
        guard Thread.isMainThread else { return }
        rebuildSessions()
        rebuildDetail()
    }

    private func build() {
        let toolbar = NSStackView(views: [title, NSView(), stopAll])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        stopAll.title = AgentActivityStrings.stopAll
        stopAll.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: AgentActivityStrings.stopAll)
        stopAll.imagePosition = .imageLeading
        stopAll.bezelStyle = .rounded
        stopAll.target = self
        stopAll.action = #selector(stopAllPressed)

        sessionStack.orientation = .vertical
        sessionStack.alignment = .width
        sessionStack.spacing = 2
        let sessionScroll = NSScrollView()
        sessionScroll.drawsBackground = false
        sessionScroll.hasVerticalScroller = true
        sessionScroll.documentView = sessionStack

        eventStack.orientation = .vertical
        eventStack.alignment = .width
        eventStack.spacing = 0
        let eventScroll = NSScrollView()
        eventScroll.drawsBackground = false
        eventScroll.hasVerticalScroller = true
        eventScroll.documentView = eventStack

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignCenter
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        preview.layer?.cornerRadius = 8
        filmstrip.heightAnchor.constraint(equalToConstant: 86).isActive = true

        let detail = NSStackView(views: [preview, filmstrip, eventScroll])
        detail.orientation = .vertical
        detail.alignment = .width
        detail.spacing = 8

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        let left = NSView()
        let leftStack = NSStackView(views: [sessionScroll])
        leftStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(leftStack)
        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: left.leadingAnchor), leftStack.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            leftStack.topAnchor.constraint(equalTo: left.topAnchor), leftStack.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 220), left.widthAnchor.constraint(equalToConstant: 280),
        ])
        split.addArrangedSubview(left)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.translatesAutoresizingMaskIntoConstraints = false

        addSubview(toolbar)
        addSubview(split)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: topAnchor), toolbar.heightAnchor.constraint(equalToConstant: 38),
            split.leadingAnchor.constraint(equalTo: leadingAnchor), split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: toolbar.bottomAnchor), split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func rebuildSessions() {
        sessionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for group in model.groups {
            let header = NSTextField(labelWithString: group.name)
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .secondaryLabelColor
            sessionStack.addArrangedSubview(header)
            for session in group.sessions {
                let button = NSButton(title: "\(session.agentName)  ·  \(session.label)", target: self, action: #selector(sessionPressed(_:)))
                button.alignment = .left
                button.bezelStyle = .texturedRounded
                button.identifier = NSUserInterfaceItemIdentifier(session.id)
                button.toolTip = AgentActivityStrings.status(session.status)
                if session.id == model.selectedSessionID { button.state = .on }
                sessionStack.addArrangedSubview(button)
            }
        }
        stopAll.isEnabled = model.liveLocalCount > 0
    }

    private func rebuildDetail() {
        eventStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let session = model.selectedSession else {
            preview.image = nil
            filmstrip.configure(events: [], model: model)
            return
        }
        filmstrip.configure(events: model.selectedEvents, model: model)
        if let frame = model.currentFrameEvent?.displayFrame {
            Task { @MainActor [weak self, model] in self?.preview.image = await model.image(for: frame) }
        } else {
            preview.image = nil
        }
        for event in model.selectedEvents.reversed() {
            let row = NSButton(title: "\(AgentActivityFormat.time(event.time))  \(event.tool ?? event.kind.rawValue)", target: self, action: #selector(eventPressed(_:)))
            row.alignment = .left
            row.bezelStyle = .recessed
            row.identifier = NSUserInterfaceItemIdentifier(String(event.seq))
            row.toolTip = event.target
            eventStack.addArrangedSubview(row)
        }
        title.stringValue = "\(AgentActivityStrings.title)  ·  \(session.agentName)"
    }

    @objc private func sessionPressed(_ sender: NSButton) { model.select(session: sender.identifier?.rawValue) }

    @objc private func eventPressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let seq = UInt64(raw) else { return }
        model.scrub(to: seq)
    }

    @objc private func stopAllPressed() { model.stopAll() }
}
