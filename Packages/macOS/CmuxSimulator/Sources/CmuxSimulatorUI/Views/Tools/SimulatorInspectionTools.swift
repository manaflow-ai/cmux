import AppKit
import CmuxSimulator

@MainActor
final class SimulatorInspectionTools: SimulatorToolSection, SimulatorToolsSection {
    private let coordinator: SimulatorPaneCoordinator
    private let foregroundButton = SimulatorClosureButton(
        title: String(localized: simulatorStrings.foregroundApp)
    )
    private let accessibilityButton = SimulatorClosureButton(
        title: String(localized: simulatorStrings.accessibility)
    )
    private let overlaySwitch = SimulatorClosureSwitch(
        title: String(localized: simulatorStrings.accessibilityOverlay)
    )
    private let applicationStack = NSStackView()
    private let accessibilitySummary = simulatorLabel("", color: .secondaryLabelColor)
    private let accessibilityWarning = simulatorLabel("", color: .systemOrange)
    private let accessibilityTree = SimulatorAccessibilityPagedTree()
    private let clearHighlight = SimulatorClosureButton(
        title: String(localized: simulatorStrings.clearHighlight)
    )
    private var applicationSignature = ""
    private var lastFrameTransportSignature = ""
    private var isSynchronizing = false

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
        super.init(simulatorStrings.inspect)
        foregroundButton.handler = { [weak coordinator] in
            coordinator?.scheduleControlAction("refresh-foreground") {
                await $0.refreshForegroundApplication()
            }
        }
        accessibilityButton.handler = { [weak coordinator] in
            coordinator?.scheduleControlAction("refresh-accessibility") {
                await $0.refreshAccessibility()
            }
        }
        overlaySwitch.handler = { [weak self] enabled in
            guard let self, !isSynchronizing else { return }
            coordinator.setAccessibilityOverlayEnabled(enabled)
        }
        clearHighlight.handler = { [weak coordinator] in
            coordinator?.scheduleControlAction("accessibility-highlight") {
                await $0.clearAccessibilityHighlight()
            }
        }
        applicationStack.orientation = .vertical
        applicationStack.alignment = .leading
        applicationStack.spacing = 4
        add(foregroundButton)
        add(applicationStack)
        add(accessibilityButton)
        add(overlaySwitch)
        add(accessibilitySummary)
        add(accessibilityWarning)
        add(accessibilityTree)
        add(clearHighlight)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update() {
        foregroundButton.isEnabled = coordinator.supports(.foregroundApplication)
        accessibilityButton.isEnabled = coordinator.supports(.accessibility)
        overlaySwitch.isEnabled = coordinator.supports(.accessibility)
        isSynchronizing = true
        overlaySwitch.state = coordinator.accessibilityOverlayEnabled ? .on : .off
        isSynchronizing = false
        let frameSignature = String(describing: coordinator.frameTransport)
        if frameSignature != lastFrameTransportSignature {
            lastFrameTransportSignature = frameSignature
            if coordinator.frameTransport != nil {
                Task { @MainActor [weak coordinator] in
                    await coordinator?.refreshForegroundApplication()
                    await coordinator?.refreshAccessibility()
                }
            }
        }
        updateApplication()
        updateAccessibility()
    }

    private func updateApplication() {
        let nextSignature = String(describing: coordinator.foregroundApplication)
        guard nextSignature != applicationSignature else { return }
        applicationSignature = nextSignature
        applicationStack.arrangedSubviews.forEach {
            applicationStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard let application = coordinator.foregroundApplication else { return }
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        if let bundlePath = application.bundlePath {
            let image = NSImageView(image: NSWorkspace.shared.icon(forFile: bundlePath))
            image.imageScaling = .scaleProportionallyUpOrDown
            image.widthAnchor.constraint(equalToConstant: 32).isActive = true
            image.heightAnchor.constraint(equalToConstant: 32).isActive = true
            header.addArrangedSubview(image)
        }
        let titles = NSStackView(views: [
            simulatorLabel(application.name ?? application.bundleIdentifier),
            simulatorLabel(application.bundleIdentifier, color: .secondaryLabelColor),
        ])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        header.addArrangedSubview(titles)
        addApplicationView(header)
        if let value = application.processIdentifier {
            addApplicationView(simulatorValueRow(simulatorStrings.processIdentifier, value: String(value)))
        }
        if let value = application.version {
            addApplicationView(simulatorValueRow(simulatorStrings.version, value: value))
        }
        if let value = application.build {
            addApplicationView(simulatorValueRow(simulatorStrings.build, value: value))
        }
        if let value = application.minimumOSVersion {
            addApplicationView(simulatorValueRow(simulatorStrings.minimumOSVersion, value: value))
        }
        if let value = application.executable {
            addApplicationView(simulatorValueRow(simulatorStrings.executable, value: value))
        }
        if let bundlePath = application.bundlePath {
            addApplicationView(simulatorValueRow(simulatorStrings.applicationPath, value: bundlePath))
            addApplicationView(SimulatorClosureButton(
                title: String(localized: simulatorStrings.revealInFinder),
                handler: {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        URL(fileURLWithPath: bundlePath, isDirectory: true),
                    ])
                }
            ))
        }
        addApplicationView(simulatorValueRow(
            simulatorStrings.reactNative,
            value: String(localized: application.isReactNative ? simulatorStrings.yes : simulatorStrings.no)
        ))
        if application.isReactNative {
            addApplicationView(SimulatorClosureButton(
                title: String(localized: simulatorStrings.reloadReactNative),
                handler: { [weak coordinator] in
                    coordinator?.scheduleControlAction("reload-react-native") {
                        await $0.reloadReactNative()
                    }
                }
            ))
        }
    }

    private func addApplicationView(_ view: NSView) {
        applicationStack.addArrangedSubview(view)
        view.widthAnchor.constraint(lessThanOrEqualTo: applicationStack.widthAnchor).isActive = true
    }

    private func updateAccessibility() {
        guard let snapshot = coordinator.accessibilitySnapshot else {
            accessibilitySummary.isHidden = true
            accessibilityWarning.isHidden = true
            accessibilityTree.isHidden = true
            clearHighlight.isHidden = true
            return
        }
        accessibilitySummary.isHidden = false
        accessibilitySummary.stringValue = String(localized: simulatorStrings.accessibilityNodeCount(snapshot.nodeCount))
        accessibilityWarning.isHidden = !snapshot.isTruncated
        accessibilityWarning.stringValue = String(localized: simulatorStrings.accessibilityTruncated)
        accessibilityTree.isHidden = false
        accessibilityTree.update(
            rows: coordinator.accessibilityRows,
            highlightedNodeID: coordinator.highlightedAccessibilityNodeID,
            onSelect: { [weak coordinator] node in
                coordinator?.scheduleControlAction("accessibility-highlight") {
                    await $0.highlightAccessibilityNode(node)
                }
            }
        )
        clearHighlight.isHidden = coordinator.highlightedAccessibilityNodeID == nil
    }
}
