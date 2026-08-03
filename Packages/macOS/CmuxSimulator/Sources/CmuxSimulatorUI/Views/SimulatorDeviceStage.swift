import AppKit
import CmuxSimulator

let simulatorDeviceStagePadding: CGFloat = 22

@MainActor
final class SimulatorDeviceStage: NSView {
    private let coordinator: SimulatorPaneCoordinator
    private let surface = SimulatorRemoteSurfaceView()
    private let overlay = SimulatorAccessibilityOverlay()
    private let statusStack = NSStackView()
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let statusButton = SimulatorClosureButton()
    private var backgroundColor = NSColor.windowBackgroundColor
    private var lastStatusSignature = ""

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        surface.wantsLayer = true
        surface.layer?.shadowColor = NSColor.black.cgColor
        surface.layer?.shadowOpacity = 0.28
        surface.layer?.shadowRadius = 18
        surface.layer?.shadowOffset = CGSize(width: 0, height: -8)
        addSubview(surface)
        overlay.coordinator = coordinator
        addSubview(overlay)

        statusStack.orientation = .vertical
        statusStack.alignment = .centerX
        statusStack.spacing = 10
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        progress.style = .spinning
        progress.controlSize = .small
        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        statusButton.bezelStyle = .rounded
        statusStack.addArrangedSubview(progress)
        statusStack.addArrangedSubview(statusLabel)
        statusStack.addArrangedSubview(statusButton)
        addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusStack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -44),
        ])
        setAccessibilityLabel(String(localized: simulatorStrings.simulator))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        backgroundColor: NSColor,
        allowsPointerInput: Bool,
        pointerEntryEventFilter: (@MainActor (NSEvent) -> Bool)?,
        onRequestPanelFocus: @escaping @MainActor () -> Void
    ) {
        self.backgroundColor = backgroundColor
        surface.setPointerInputEnabled(allowsPointerInput)
        surface.pointerEntryEventFilter = pointerEntryEventFilter
        surface.simulatorOwnerID = ObjectIdentifier(coordinator)
        surface.onMessage = { [weak coordinator] in coordinator?.enqueue($0) }
        surface.onGeometry = { [weak coordinator] in coordinator?.updateGeometry($0) }
        surface.onRequestPanelFocus = onRequestPanelFocus
        surface.onFrameTransportFailure = { [weak coordinator] descriptor, failure in
            Task { @MainActor in coordinator?.receiveFrameTransportFailure(failure, for: descriptor) }
        }
        surface.onFrameTransportAdopted = { [weak coordinator] descriptor in
            coordinator?.acknowledgeFrameTransportAdoption(descriptor)
        }

        if let display = coordinator.display, let transport = coordinator.frameTransport {
            surface.isHidden = false
            statusStack.isHidden = true
            surface.update(frameTransport: transport, display: display, chrome: coordinator.chromeProfile)
            surface.requestFocus(generation: coordinator.focusRequestGeneration)
            overlay.update(
                snapshot: coordinator.accessibilitySnapshot,
                rows: coordinator.accessibilityRows,
                selectedNodeID: coordinator.accessibilityOverlaySelectedNodeID,
                highlightedNodeID: coordinator.highlightedAccessibilityNodeID,
                chrome: coordinator.chromeProfile,
                isEnabled: coordinator.accessibilityOverlayEnabled
                    || coordinator.highlightedAccessibilityNodeID != nil
            )
            overlay.isHidden = false
        } else {
            surface.isHidden = true
            overlay.isHidden = true
            statusStack.isHidden = false
            updateStatus()
        }
        needsDisplay = true
        needsLayout = true
    }

    func teardown() {
        surface.teardown()
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        guard !surface.isHidden, let display = coordinator.display else { return }
        let available = bounds.insetBy(dx: simulatorDeviceStagePadding, dy: simulatorDeviceStagePadding)
        let aspect = coordinator.chromeProfile?.outerAspect(orientation: display.orientation)
            ?? SimulatorOrientationGeometry(display: display).displayAspectRatio
        var target = aspectFit(aspect: aspect, inside: available)
        if selectedFamily == .iPhone, let maximum = maximumDeviceSize(for: display) {
            let scale = min(1, maximum.width / target.width, maximum.height / target.height)
            target.size.width *= scale
            target.size.height *= scale
            target.origin.x = bounds.midX - target.width / 2
            target.origin.y = bounds.midY - target.height / 2
        }
        surface.frame = target.integral
        overlay.frame = surface.frame
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        coordinator.canImportDroppedFiles(draggedURLs(sender)) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = draggedURLs(sender)
        guard coordinator.canImportDroppedFiles(urls) else { return false }
        coordinator.scheduleControlAction("import-dropped-files") { await $0.importDroppedFiles(urls) }
        return true
    }

    private func draggedURLs(_ sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self])?
            .compactMap { ($0 as? NSURL) as URL? } ?? []
    }

    private func updateStatus() {
        let text: String
        let buttonTitle: String?
        let showsProgress: Bool
        let action: (() -> Void)?
        if coordinator.devices.isEmpty, coordinator.failure == nil {
            text = "\(String(localized: simulatorStrings.noDevices))\n\(String(localized: simulatorStrings.noDevicesHelp))"
            buttonTitle = String(localized: simulatorStrings.refresh)
            showsProgress = false
            action = { [weak coordinator] in
                coordinator?.scheduleControlAction("reload-devices") { _ = await $0.reloadDevices() }
            }
        } else if let failure = coordinator.failure, coordinator.frameTransport == nil {
            text = String(localized: simulatorStrings.failure(failure.code))
            buttonTitle = failure.isRecoverable ? String(localized: simulatorStrings.reconnect) : nil
            showsProgress = false
            action = failure.isRecoverable ? { [weak coordinator] in coordinator?.recover() } : nil
        } else {
            switch coordinator.status {
            case .connecting:
                text = String(localized: simulatorStrings.connecting)
                buttonTitle = nil
                showsProgress = true
                action = nil
            case .workerCrashed:
                text = String(localized: simulatorStrings.workerStopped)
                buttonTitle = String(localized: simulatorStrings.reconnect)
                showsProgress = false
                action = { [weak coordinator] in coordinator?.recover() }
            default:
                text = String(localized: simulatorStrings.selectToStart)
                buttonTitle = nil
                showsProgress = false
                action = nil
            }
        }
        let signature = "\(text)|\(buttonTitle ?? "")|\(showsProgress)"
        guard signature != lastStatusSignature else { return }
        lastStatusSignature = signature
        statusLabel.stringValue = text
        progress.isHidden = !showsProgress
        showsProgress ? progress.startAnimation(nil) : progress.stopAnimation(nil)
        statusButton.isHidden = buttonTitle == nil
        statusButton.title = buttonTitle ?? ""
        statusButton.handler = action
    }

    private var selectedFamily: SimulatorDeviceFamily? {
        coordinator.devices.first(where: { $0.id == coordinator.selectedDeviceID })?.family
    }

    private func maximumDeviceSize(for display: SimulatorDisplayMetadata) -> CGSize? {
        if let chrome = coordinator.chromeProfile {
            return switch display.orientation {
            case .portrait, .portraitUpsideDown:
                CGSize(width: chrome.portraitWidth, height: chrome.portraitHeight)
            case .landscapeLeft, .landscapeRight:
                CGSize(width: chrome.portraitHeight, height: chrome.portraitWidth)
            }
        }
        guard display.scale.isFinite, display.scale > 0 else { return nil }
        let geometry = SimulatorOrientationGeometry(display: display)
        return CGSize(
            width: Double(geometry.displayWidth) / display.scale,
            height: Double(geometry.displayHeight) / display.scale
        )
    }

    private func aspectFit(aspect: CGFloat, inside rect: CGRect) -> CGRect {
        guard aspect.isFinite, aspect > 0, rect.width > 0, rect.height > 0 else { return .zero }
        var size = rect.size
        if size.width / size.height > aspect {
            size.width = size.height * aspect
        } else {
            size.height = size.width / aspect
        }
        return CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
class SimulatorClosureButton: NSButton {
    var handler: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(invoke)
    }

    convenience init(title: String = "", imageName: String? = nil, handler: (() -> Void)? = nil) {
        self.init(frame: .zero)
        self.title = title
        self.handler = handler
        if let imageName {
            image = NSImage(systemSymbolName: imageName, accessibilityDescription: title)
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler?()
    }
}
