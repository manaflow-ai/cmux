import AppKit
import CmuxSimulator

@MainActor
final class SimulatorPaneToolbar: NSView {
    private let coordinator: SimulatorPaneCoordinator
    private let stack = NSStackView()
    private let devicePicker = NSPopUpButton()
    private let statusSpinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let rotateLeftButton = SimulatorClosureButton()
    private let rotateRightButton = SimulatorClosureButton()
    private let keyboardButton = SimulatorClosureButton()
    private let homeButton = SimulatorClosureButton()
    private let appSwitcherButton = SimulatorClosureButton()
    private let lockButton = SimulatorClosureButton()
    private let toolsButton = SimulatorClosureButton()
    private var pickerSignature = ""

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        devicePicker.bezelStyle = .inline
        devicePicker.controlSize = .small
        devicePicker.target = self
        devicePicker.action = #selector(selectDevice)
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .mini
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(devicePicker)
        stack.addArrangedSubview(statusSpinner)
        stack.addArrangedSubview(statusLabel)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        configure(rotateLeftButton, title: simulatorStrings.rotateLeft, symbol: "rotate.left") {
            [weak coordinator] in coordinator?.rotateLeft()
        }
        configure(rotateRightButton, title: simulatorStrings.rotateRight, symbol: "rotate.right") {
            [weak coordinator] in coordinator?.rotateRight()
        }
        configure(keyboardButton, title: simulatorStrings.keyboard, symbol: "keyboard") {
            [weak coordinator] in coordinator?.toggleSoftwareKeyboard()
        }
        configure(homeButton, title: simulatorStrings.home, symbol: "house") {
            [weak coordinator] in coordinator?.press(.home)
        }
        configure(appSwitcherButton, title: simulatorStrings.appSwitcher, symbol: "square.on.square") {
            [weak coordinator] in coordinator?.press(.appSwitcher)
        }
        configure(lockButton, title: simulatorStrings.lock, symbol: "lock") {
            [weak coordinator] in coordinator?.press(.lock)
        }
        for button in [rotateLeftButton, rotateRightButton, keyboardButton, homeButton, appSwitcherButton, lockButton] {
            stack.addArrangedSubview(button)
        }
        let divider = NSBox()
        divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        stack.addArrangedSubview(divider)
        configure(toolsButton, title: simulatorStrings.tools, symbol: "slider.horizontal.3") {
            [weak coordinator] in coordinator?.showsTools.toggle()
        }
        stack.addArrangedSubview(toolsButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update() {
        updatePicker()
        statusSpinner.isHidden = coordinator.status != .connecting
        coordinator.status == .connecting ? statusSpinner.startAnimation(nil) : statusSpinner.stopAnimation(nil)
        statusLabel.stringValue = switch coordinator.status {
        case .idle: String(localized: simulatorStrings.selectToStart)
        case .connecting: String(localized: simulatorStrings.connecting)
        case .streaming: String(localized: simulatorStrings.streaming)
        case .deviceUnavailable: String(localized: simulatorStrings.unavailable)
        case .workerCrashed: String(localized: simulatorStrings.workerStopped)
        case .failed: String(localized: simulatorStrings.failed)
        }
        statusLabel.textColor = coordinator.status == .streaming ? .systemGreen : .secondaryLabelColor
        rotateLeftButton.isEnabled = coordinator.supports(.rotation)
        rotateRightButton.isEnabled = coordinator.supports(.rotation)
        keyboardButton.isEnabled = coordinator.supports(.keyboard)
        let hardwareEnabled = coordinator.supports(.hardwareButtons)
        homeButton.isEnabled = hardwareEnabled
        appSwitcherButton.isEnabled = hardwareEnabled
        lockButton.isEnabled = hardwareEnabled
        toolsButton.state = coordinator.showsTools ? .on : .off
    }

    private func configure(
        _ button: SimulatorClosureButton,
        title: LocalizedStringResource,
        symbol: String,
        action: @escaping () -> Void
    ) {
        let localized = String(localized: title)
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: localized)
        button.imagePosition = .imageOnly
        button.toolTip = localized
        button.bezelStyle = .inline
        button.controlSize = .small
        button.handler = action
    }

    private func updatePicker() {
        let snapshot = simulatorDevicePickerSnapshot(
            devices: coordinator.devices,
            selectedDeviceID: coordinator.selectedDeviceID,
            localizedState: { String(localized: simulatorStrings.deviceState($0)) }
        )
        let signature = snapshot.rows.map { "\($0.id):\($0.label):\($0.isSelected)" }.joined(separator: "|")
        guard signature != pickerSignature else { return }
        pickerSignature = signature
        devicePicker.removeAllItems()
        if snapshot.rows.isEmpty {
            devicePicker.addItem(withTitle: String(localized: simulatorStrings.refresh))
            devicePicker.lastItem?.representedObject = "__refresh__"
        } else {
            for row in snapshot.rows {
                devicePicker.addItem(withTitle: row.label)
                devicePicker.lastItem?.representedObject = row.id
                devicePicker.lastItem?.state = row.isSelected ? .on : .off
            }
            devicePicker.menu?.addItem(.separator())
            let refresh = NSMenuItem(title: String(localized: simulatorStrings.refresh), action: nil, keyEquivalent: "")
            refresh.representedObject = "__refresh__"
            devicePicker.menu?.addItem(refresh)
            if let selected = snapshot.rows.firstIndex(where: \.isSelected) {
                devicePicker.selectItem(at: selected)
            }
        }
    }

    @objc private func selectDevice() {
        guard let id = devicePicker.selectedItem?.representedObject as? String else { return }
        if id == "__refresh__" {
            coordinator.scheduleControlAction("reload-devices") { _ = await $0.reloadDevices() }
        } else {
            coordinator.selectDevice(id: id)
        }
    }
}
