import AppKit
import Observation

/// AppKit composition root for one isolated iPhone or iPad Simulator pane.
@MainActor
public final class SimulatorPaneView: NSViewController {
    private let coordinator: SimulatorPaneCoordinator
    private var backgroundColor: NSColor
    private var allowsPointerInput: Bool
    private var pointerEntryEventFilter: (@MainActor (NSEvent) -> Bool)?
    private var onRequestPanelFocus: @MainActor () -> Void
    private let toolbarView: SimulatorPaneToolbar
    private let stageView: SimulatorDeviceStage
    private let toolsView: SimulatorToolsPanel
    private let separator = NSBox()
    private let toolsSeparator = NSBox()
    private let visibilityView = SimulatorHostWindowVisibilityView()
    private let visibilityCoordinator = SimulatorHostWindowVisibilityCoordinator()
    private var toolsWidthConstraint: NSLayoutConstraint?
    private var observationGeneration: UInt64 = 0
    private var isTornDown = false

    /// Creates a native Simulator pane.
    public init(
        coordinator: SimulatorPaneCoordinator,
        backgroundColor: NSColor,
        allowsPointerInput: Bool,
        pointerEntryEventFilter: (@MainActor (NSEvent) -> Bool)? = nil,
        onRequestPanelFocus: @escaping @MainActor () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.backgroundColor = backgroundColor
        self.allowsPointerInput = allowsPointerInput
        self.pointerEntryEventFilter = pointerEntryEventFilter
        self.onRequestPanelFocus = onRequestPanelFocus
        toolbarView = SimulatorPaneToolbar(coordinator: coordinator)
        stageView = SimulatorDeviceStage(coordinator: coordinator)
        toolsView = SimulatorToolsPanel(coordinator: coordinator)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        let root = SimulatorPaneRootView()
        root.backgroundColor = backgroundColor
        view = root

        separator.boxType = .separator
        toolsSeparator.boxType = .separator
        for child in [toolbarView, separator, stageView, toolsSeparator, toolsView, visibilityView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        toolsWidthConstraint = toolsView.widthAnchor.constraint(equalToConstant: 270)
        NSLayoutConstraint.activate([
            toolbarView.topAnchor.constraint(equalTo: root.topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 36),
            separator.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            stageView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            stageView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stageView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            toolsSeparator.topAnchor.constraint(equalTo: separator.bottomAnchor),
            toolsSeparator.leadingAnchor.constraint(equalTo: stageView.trailingAnchor),
            toolsSeparator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            toolsSeparator.widthAnchor.constraint(equalToConstant: 1),
            toolsView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            toolsView.leadingAnchor.constraint(equalTo: toolsSeparator.trailingAnchor),
            toolsView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolsView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            toolsWidthConstraint!,
            visibilityView.widthAnchor.constraint(equalToConstant: 0),
            visibilityView.heightAnchor.constraint(equalToConstant: 0),
            visibilityView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            visibilityView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        visibilityCoordinator.onRemoval = { [weak coordinator] observerID in
            coordinator?.removeHostWindowVisibilityObserver(observerID)
        }
        let observerID = visibilityCoordinator.observerID
        visibilityView.setVisibilityHandler { [weak coordinator] isVisible in
            coordinator?.setHostWindowVisibility(isVisible, for: observerID)
        }
        observeCoordinator()
    }

    /// Updates host-owned presentation inputs without rebuilding the pane.
    public func update(
        backgroundColor: NSColor,
        allowsPointerInput: Bool,
        pointerEntryEventFilter: (@MainActor (NSEvent) -> Bool)? = nil,
        onRequestPanelFocus: @escaping @MainActor () -> Void = {}
    ) {
        self.backgroundColor = backgroundColor
        self.allowsPointerInput = allowsPointerInput
        self.pointerEntryEventFilter = pointerEntryEventFilter
        self.onRequestPanelFocus = onRequestPanelFocus
        (viewIfLoaded as? SimulatorPaneRootView)?.backgroundColor = backgroundColor
        render()
    }

    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        observationGeneration &+= 1
        stageView.teardown()
        visibilityView.teardown()
        visibilityCoordinator.remove()
        coordinator.releaseInputs()
    }

    private func observeCoordinator() {
        guard !isTornDown else { return }
        observationGeneration &+= 1
        let generation = observationGeneration
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !isTornDown, observationGeneration == generation else { return }
                observeCoordinator()
            }
        }
    }

    private func render() {
        guard isViewLoaded, !isTornDown else { return }
        toolbarView.update()
        stageView.update(
            backgroundColor: backgroundColor,
            allowsPointerInput: allowsPointerInput,
            pointerEntryEventFilter: pointerEntryEventFilter,
            onRequestPanelFocus: onRequestPanelFocus
        )
        toolsView.update(backgroundColor: backgroundColor)
        let showsTools = coordinator.showsTools
        toolsView.isHidden = !showsTools
        toolsSeparator.isHidden = !showsTools
        toolsWidthConstraint?.isActive = showsTools
        view.needsLayout = true
    }
}

@MainActor
private final class SimulatorPaneRootView: NSView {
    var backgroundColor = NSColor.windowBackgroundColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
    }
}
