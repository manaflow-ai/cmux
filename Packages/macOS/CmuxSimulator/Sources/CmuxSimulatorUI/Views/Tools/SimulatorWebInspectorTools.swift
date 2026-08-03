import AppKit
import CmuxSimulator

@MainActor
final class SimulatorWebInspectorTools: SimulatorToolSection, SimulatorToolsSection {
    private let coordinator: SimulatorPaneCoordinator
    private let targetPicker = SimulatorClosurePopUpButton()
    private let attachButton = SimulatorClosureButton(title: String(localized: simulatorStrings.chooseTarget))
    private let releaseButton = SimulatorClosureButton(title: String(localized: simulatorStrings.releaseInspector))
    private let statusLabel = simulatorLabel("", color: .secondaryLabelColor)
    private let targetDetails = simulatorLabel("", color: .secondaryLabelColor)
    private let highlightButton = SimulatorClosureButton()
    private let command = SimulatorClosureTextView(
        value: #"{"id":1,"method":"Runtime.evaluate","params":{"expression":"document.title"}}"#,
        minimumHeight: 88
    )
    private let sendButton = SimulatorClosureButton(title: String(localized: simulatorStrings.sendInspectorCommand))
    private let clearButton = SimulatorClosureButton(title: String(localized: simulatorStrings.clearInspectorResponses))
    private let responsesStack = NSStackView()
    private var targetIDs = [String]()
    private var responseSignature = ""
    private var lastFrameTransportSignature = ""

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
        super.init(simulatorStrings.webInspector)
        let refresh = SimulatorClosureButton(title: String(localized: simulatorStrings.refreshTargets)) {
            [weak coordinator] in
            coordinator?.scheduleControlAction("web-inspector-refresh") {
                await $0.refreshWebInspectorTargets()
            }
        }
        refresh.identifier = NSUserInterfaceItemIdentifier("refresh")
        targetPicker.handler = { [weak self] _ in self?.updateButtonState() }
        attachButton.handler = { [weak self] in self?.attach() }
        releaseButton.handler = { [weak coordinator] in
            coordinator?.scheduleControlAction("web-inspector-session") {
                await $0.releaseWebInspector()
            }
        }
        add(simulatorRow([refresh, targetPicker, attachButton, releaseButton]))
        add(statusLabel)
        add(targetDetails)
        highlightButton.handler = { [weak self] in self?.toggleHighlight() }
        sendButton.handler = { [weak self] in self?.sendCommand() }
        command.textView.setAccessibilityLabel(String(localized: simulatorStrings.rawInspectorRequest))
        command.onChange = { [weak self] _ in self?.updateButtonState() }
        add(simulatorRow([highlightButton, sendButton]))
        add(command)
        let responseTitle = simulatorLabel(
            String(localized: simulatorStrings.inspectorResponses),
            font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        )
        clearButton.handler = { [weak coordinator] in coordinator?.clearWebInspectorResponses() }
        add(simulatorRow([responseTitle, clearButton]))
        responsesStack.orientation = .vertical
        responsesStack.alignment = .leading
        responsesStack.spacing = 6
        add(responsesStack)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update() {
        let frameSignature = String(describing: coordinator.frameTransport)
        if frameSignature != lastFrameTransportSignature {
            lastFrameTransportSignature = frameSignature
            if coordinator.frameTransport != nil, coordinator.supports(.webInspector) {
                Task { @MainActor [weak coordinator] in await coordinator?.refreshWebInspectorTargets() }
            }
        }
        updateTargets()
        updateButtonState()
        updateResponses()
    }

    private func updateTargets() {
        let targets = coordinator.webInspectorTargets
        let nextIDs = targets.map(\.id)
        if nextIDs != targetIDs {
            let selectedID = selectedTargetID
            targetIDs = nextIDs
            targetPicker.removeAllItems()
            targetPicker.addItems(withTitles: targets.map(targetLabel))
            if let selectedID, let index = targetIDs.firstIndex(of: selectedID) {
                targetPicker.selectItem(at: index)
            }
        }
        let available = coordinator.supports(.webInspector)
        statusLabel.stringValue = targets.isEmpty
            ? String(localized: available
                ? simulatorStrings.noInspectorTargets
                : simulatorStrings.webInspectorUnavailable)
            : ""
        statusLabel.isHidden = !targets.isEmpty
        if let target = attachedTarget {
            let title = target.title.isEmpty ? target.url : target.title
            targetDetails.stringValue = "\(title)\n\(target.url)\n\(target.bundleIdentifier ?? target.applicationName)"
            targetDetails.isHidden = false
        } else {
            targetDetails.isHidden = true
        }
    }

    private func updateButtonState() {
        let available = coordinator.supports(.webInspector)
        let attached = attachedTargetID != nil
        let selectedTarget = coordinator.webInspectorTargets.first(where: { $0.id == selectedTargetID })
        (contentStack.arrangedSubviews.first?.subviews.first(where: { $0.identifier?.rawValue == "refresh" }) as? NSButton)?.isEnabled = available
        targetPicker.isEnabled = available && !targetIDs.isEmpty
        attachButton.isEnabled = available && selectedTarget != nil && selectedTarget?.isInUse == false
        releaseButton.isHidden = !attached
        highlightButton.title = String(localized: coordinator.webInspectorIsHighlighted
            ? simulatorStrings.unhighlightPage
            : simulatorStrings.highlightPage)
        highlightButton.isEnabled = attached
        sendButton.isEnabled = attached
            && !command.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func updateResponses() {
        let responses = coordinator.webInspectorResponses
        clearButton.isEnabled = !responses.isEmpty
        let nextSignature = responses.map { "\($0.id):\($0.isTruncated):\($0.text)" }.joined(separator: "|")
        guard nextSignature != responseSignature else { return }
        responseSignature = nextSignature
        responsesStack.arrangedSubviews.forEach {
            responsesStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if responses.isEmpty {
            responsesStack.addArrangedSubview(simulatorLabel(
                String(localized: simulatorStrings.noInspectorResponses),
                color: .secondaryLabelColor
            ))
            return
        }
        for response in responses {
            let text = (response.isTruncated
                ? "\(String(localized: simulatorStrings.truncatedInspectorResponse))\n"
                : "") + response.text
            let label = simulatorLabel(
                text,
                font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
            )
            responsesStack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: responsesStack.widthAnchor).isActive = true
        }
    }

    private var selectedTargetID: String? {
        guard targetIDs.indices.contains(targetPicker.indexOfSelectedItem) else { return nil }
        return targetIDs[targetPicker.indexOfSelectedItem]
    }

    private var attachedTargetID: String? {
        guard case let .attached(_, targetID) = coordinator.webInspectorSession else { return nil }
        return targetID
    }

    private var attachedTarget: SimulatorWebInspectorTarget? {
        guard let attachedTargetID else { return nil }
        return coordinator.webInspectorTargets.first(where: { $0.id == attachedTargetID })
    }

    private func attach() {
        guard let targetID = selectedTargetID else { return }
        coordinator.scheduleControlAction("web-inspector-session") {
            await $0.attachWebInspector(targetID: targetID)
        }
    }

    private func toggleHighlight() {
        let enabled = !coordinator.webInspectorIsHighlighted
        coordinator.scheduleControlAction("web-inspector-highlight") {
            await $0.setWebInspectorHighlight(enabled: enabled)
        }
    }

    private func sendCommand() {
        let json = command.string
        coordinator.scheduleControlAction("web-inspector-send") {
            await $0.sendWebInspectorMessage(json)
        }
    }

    private func targetLabel(_ target: SimulatorWebInspectorTarget) -> String {
        let page = target.title.isEmpty ? target.url : target.title
        let suffix = target.isInUse ? " · \(String(localized: simulatorStrings.inUse))" : ""
        return "\(target.applicationName) · \(page)\(suffix)"
    }
}
