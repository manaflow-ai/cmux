import AppKit
import CmuxSimulator

@MainActor
class SimulatorAppearanceToolsContent: SimulatorToolSection, SimulatorToolsSection {
    private let coordinator: SimulatorPaneCoordinator
    private let appearancePicker = SimulatorClosurePopUpButton()
    private let contentSizePicker = SimulatorClosurePopUpButton()
    private let increaseContrast = SimulatorClosureSwitch(title: String(localized: simulatorStrings.increaseContrast))
    private let liquidGlassPicker = SimulatorClosurePopUpButton()
    private let colorFilterPicker = SimulatorClosurePopUpButton()
    private let reduceMotion = SimulatorClosureSwitch(title: String(localized: simulatorStrings.reduceMotion))
    private let buttonShapes = SimulatorClosureSwitch(title: String(localized: simulatorStrings.buttonShapes))
    private let reduceTransparency = SimulatorClosureSwitch(title: String(localized: simulatorStrings.reduceTransparency))
    private let voiceOver = SimulatorClosureSwitch(title: String(localized: simulatorStrings.voiceOver))
    private let time = SimulatorClosureTextField(value: "9:41")
    private let carrier = SimulatorClosureTextField(value: "cmux")
    private let dataNetworkPicker = SimulatorClosurePopUpButton()
    private let wifiModePicker = SimulatorClosurePopUpButton()
    private let wifiBars = SimulatorClosureTextField(value: "3")
    private let cellularModePicker = SimulatorClosurePopUpButton()
    private let cellularBars = SimulatorClosureTextField(value: "4")
    private let batteryStatePicker = SimulatorClosurePopUpButton()
    private let battery = SimulatorClosureTextField(value: "100")
    private let appearances = SimulatorInterfaceSetting.Appearance.allCases
    private let contentSizes = SimulatorInterfaceSetting.ContentSize.allCases
    private let liquidGlasses = SimulatorInterfaceSetting.LiquidGlass.allCases
    private let colorFilters = SimulatorInterfaceSetting.ColorFilter.allCases
    private let dataNetworks = SimulatorStatusBarOverride.DataNetwork.allCases
    private let wifiModes = SimulatorStatusBarOverride.ConnectionMode.allCases
    private let cellularModes = SimulatorStatusBarOverride.CellularMode.allCases
    private let batteryStates = SimulatorStatusBarOverride.BatteryState.allCases
    private var isSynchronizing = false
    private var lastHydratedDeviceID: String?

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
        super.init(simulatorStrings.appearance)
        appearancePicker.addItems(withTitles: [
            String(localized: simulatorStrings.light),
            String(localized: simulatorStrings.dark),
        ])
        contentSizePicker.addItems(withTitles: contentSizes.map {
            String(localized: simulatorStrings.contentSize($0))
        })
        contentSizePicker.selectItem(at: contentSizes.firstIndex(of: .large) ?? 0)
        liquidGlassPicker.addItems(withTitles: [
            String(localized: simulatorStrings.clear),
            String(localized: simulatorStrings.tinted),
        ])
        colorFilterPicker.addItems(withTitles: colorFilters.map {
            String(localized: simulatorStrings.colorFilter($0))
        })
        dataNetworkPicker.addItems(withTitles: dataNetworks.map {
            String(localized: simulatorStrings.dataNetwork($0))
        })
        dataNetworkPicker.selectItem(at: dataNetworks.firstIndex(of: .wifi) ?? 0)
        wifiModePicker.addItems(withTitles: wifiModes.map {
            String(localized: simulatorStrings.connection($0))
        })
        wifiModePicker.selectItem(at: wifiModes.firstIndex(of: .active) ?? 0)
        cellularModePicker.addItems(withTitles: cellularModes.map {
            String(localized: simulatorStrings.cellular($0))
        })
        cellularModePicker.selectItem(at: cellularModes.firstIndex(of: .active) ?? 0)
        batteryStatePicker.addItems(withTitles: batteryStates.map {
            String(localized: simulatorStrings.battery($0))
        })
        batteryStatePicker.selectItem(at: batteryStates.firstIndex(of: .charged) ?? 0)
        time.placeholderString = String(localized: simulatorStrings.statusTime)
        carrier.placeholderString = String(localized: simulatorStrings.carrier)
        wifiBars.placeholderString = String(localized: simulatorStrings.wifiBars)
        cellularBars.placeholderString = String(localized: simulatorStrings.cellularBars)
        battery.placeholderString = String(localized: simulatorStrings.batteryLevel)

        add(labeled(simulatorStrings.appearance, appearancePicker))
        add(labeled(simulatorStrings.contentSize, contentSizePicker))
        add(increaseContrast)
        add(labeled(simulatorStrings.liquidGlass, liquidGlassPicker))
        add(labeled(simulatorStrings.colorFilter, colorFilterPicker))
        add(reduceMotion)
        add(buttonShapes)
        add(reduceTransparency)
        add(voiceOver)
        add(time)
        add(carrier)
        add(labeled(simulatorStrings.dataNetwork, dataNetworkPicker))
        add(labeled(simulatorStrings.wifiMode, wifiModePicker))
        add(wifiBars)
        add(labeled(simulatorStrings.cellularMode, cellularModePicker))
        add(cellularBars)
        add(labeled(simulatorStrings.batteryState, batteryStatePicker))
        add(battery)
        let apply = SimulatorClosureButton(title: String(localized: simulatorStrings.applyStatusBar)) {
            [weak self] in self?.applyStatusBar()
        }
        let clear = SimulatorClosureButton(title: String(localized: simulatorStrings.clearStatusBar)) {
            [weak coordinator] in
            coordinator?.scheduleControlAction("status-bar") { await $0.clearStatusBar() }
        }
        add(simulatorRow([apply, clear]))

        appearancePicker.handler = { [weak self] index in
            guard let self, !isSynchronizing, appearances.indices.contains(index) else { return }
            let value = appearances[index]
            coordinator.scheduleControlAction("interface-appearance") {
                await $0.setInterface(.appearance(value))
            }
        }
        contentSizePicker.handler = { [weak self] index in
            guard let self, !isSynchronizing, contentSizes.indices.contains(index) else { return }
            let value = contentSizes[index]
            coordinator.scheduleControlAction("interface-content-size") {
                await $0.setInterface(.contentSize(value))
            }
        }
        liquidGlassPicker.handler = { [weak self] index in
            guard let self, !isSynchronizing, liquidGlasses.indices.contains(index) else { return }
            let value = liquidGlasses[index]
            coordinator.scheduleControlAction("interface-liquid-glass") {
                await $0.setInterface(.liquidGlass(value))
            }
        }
        colorFilterPicker.handler = { [weak self] index in
            guard let self, !isSynchronizing, colorFilters.indices.contains(index) else { return }
            let value = colorFilters[index]
            coordinator.scheduleControlAction("interface-color-filter") {
                await $0.setInterface(.colorFilter(value))
            }
        }
        configure(increaseContrast, key: "interface-contrast") { .increaseContrast($0) }
        configure(reduceMotion, key: "interface-reduce-motion") { .reduceMotion($0) }
        configure(buttonShapes, key: "interface-button-shapes") { .buttonShapes($0) }
        configure(reduceTransparency, key: "interface-reduce-transparency") { .reduceTransparency($0) }
        configure(voiceOver, key: "interface-voice-over") { .voiceOver($0) }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update() {
        if lastHydratedDeviceID != coordinator.selectedDeviceID {
            lastHydratedDeviceID = coordinator.selectedDeviceID
            Task { @MainActor [weak coordinator] in await coordinator?.refreshInterfaceStatus() }
        }
        guard let status = coordinator.interfaceStatus else { return }
        isSynchronizing = true
        if let value = status.appearance, let index = appearances.firstIndex(of: value) {
            appearancePicker.selectItem(at: index)
        }
        if let value = status.contentSize, let index = contentSizes.firstIndex(of: value) {
            contentSizePicker.selectItem(at: index)
        }
        if let value = status.increaseContrast { increaseContrast.state = value ? .on : .off }
        liquidGlassPicker.selectItem(at: liquidGlasses.firstIndex(of: status.liquidGlass) ?? 0)
        colorFilterPicker.selectItem(at: colorFilters.firstIndex(of: status.colorFilter) ?? 0)
        reduceMotion.state = status.reduceMotion ? .on : .off
        buttonShapes.state = status.buttonShapes ? .on : .off
        reduceTransparency.state = status.reduceTransparency ? .on : .off
        voiceOver.state = status.voiceOver ? .on : .off
        isSynchronizing = false
    }

    private func labeled(_ title: LocalizedStringResource, _ control: NSView) -> NSStackView {
        let label = simulatorLabel(String(localized: title), color: .secondaryLabelColor)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return simulatorRow([label, spacer, control])
    }

    private func configure(
        _ control: SimulatorClosureSwitch,
        key: String,
        setting: @escaping @Sendable (Bool) -> SimulatorInterfaceSetting
    ) {
        control.handler = { [weak self] enabled in
            guard let self, !isSynchronizing else { return }
            coordinator.scheduleControlAction(key) { await $0.setInterface(setting(enabled)) }
        }
    }

    private func applyStatusBar() {
        guard dataNetworks.indices.contains(dataNetworkPicker.indexOfSelectedItem),
              wifiModes.indices.contains(wifiModePicker.indexOfSelectedItem),
              cellularModes.indices.contains(cellularModePicker.indexOfSelectedItem),
              batteryStates.indices.contains(batteryStatePicker.indexOfSelectedItem) else { return }
        let values = SimulatorStatusBarOverride(
            time: time.stringValue,
            dataNetwork: dataNetworks[dataNetworkPicker.indexOfSelectedItem],
            wifiMode: wifiModes[wifiModePicker.indexOfSelectedItem],
            wifiBars: min(3, max(0, Int(wifiBars.stringValue) ?? 3)),
            cellularMode: cellularModes[cellularModePicker.indexOfSelectedItem],
            cellularBars: min(4, max(0, Int(cellularBars.stringValue) ?? 4)),
            operatorName: carrier.stringValue,
            batteryState: batteryStates[batteryStatePicker.indexOfSelectedItem],
            batteryLevel: min(100, max(0, Int(battery.stringValue) ?? 100))
        )
        coordinator.scheduleControlAction("status-bar") { await $0.overrideStatusBar(values) }
    }
}
