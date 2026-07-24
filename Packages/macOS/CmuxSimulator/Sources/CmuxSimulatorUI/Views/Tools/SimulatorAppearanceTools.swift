import CmuxSimulator
import SwiftUI

struct SimulatorAppearanceTools: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        SimulatorAppearanceToolsContent(coordinator: coordinator)
            .id(coordinator.selectedDeviceID)
    }
}

private struct SimulatorAppearanceToolsContent: View {
    let coordinator: SimulatorPaneCoordinator
    @State private var appearance: SimulatorInterfaceSetting.Appearance = .light
    @State private var contentSize: SimulatorInterfaceSetting.ContentSize = .large
    @State private var increaseContrast = false
    @State private var liquidGlass: SimulatorInterfaceSetting.LiquidGlass = .clear
    @State private var colorFilter: SimulatorInterfaceSetting.ColorFilter = .none
    @State private var reduceMotion = false
    @State private var buttonShapes = false
    @State private var reduceTransparency = false
    @State private var voiceOver = false
    @State private var time = "9:41"
    @State private var carrier = "cmux"
    @State private var dataNetwork: SimulatorStatusBarOverride.DataNetwork = .wifi
    @State private var wifiMode: SimulatorStatusBarOverride.ConnectionMode = .active
    @State private var wifiBars = 3
    @State private var cellularMode: SimulatorStatusBarOverride.CellularMode = .active
    @State private var cellularBars = 4
    @State private var batteryState: SimulatorStatusBarOverride.BatteryState = .charged
    @State private var battery = 100

    var body: some View {
        SimulatorToolSection(simulatorStrings.appearance) {
            Picker(simulatorStrings.appearance, selection: $appearance) {
                Text(simulatorStrings.light).tag(SimulatorInterfaceSetting.Appearance.light)
                Text(simulatorStrings.dark).tag(SimulatorInterfaceSetting.Appearance.dark)
            }
            .onChange(of: appearance) { _, value in
                guard coordinator.interfaceStatus?.appearance != value else { return }
                coordinator.scheduleControlAction("interface-appearance") {
                    await $0.setInterface(.appearance(value))
                }
            }
            Picker(simulatorStrings.contentSize, selection: $contentSize) {
                ForEach(SimulatorInterfaceSetting.ContentSize.allCases, id: \.rawValue) { size in
                    Text(simulatorStrings.contentSize(size)).tag(size)
                }
            }
            .onChange(of: contentSize) { _, value in
                guard coordinator.interfaceStatus?.contentSize != value else { return }
                coordinator.scheduleControlAction("interface-content-size") {
                    await $0.setInterface(.contentSize(value))
                }
            }
            Toggle(simulatorStrings.increaseContrast, isOn: $increaseContrast)
                .onChange(of: increaseContrast) { _, value in
                    guard coordinator.interfaceStatus?.increaseContrast != value else { return }
                    coordinator.scheduleControlAction("interface-contrast") {
                        await $0.setInterface(.increaseContrast(value))
                    }
                }
            Picker(simulatorStrings.liquidGlass, selection: $liquidGlass) {
                Text(simulatorStrings.clear).tag(SimulatorInterfaceSetting.LiquidGlass.clear)
                Text(simulatorStrings.tinted).tag(SimulatorInterfaceSetting.LiquidGlass.tinted)
            }
            .onChange(of: liquidGlass) { _, value in
                guard coordinator.interfaceStatus?.liquidGlass != value else { return }
                coordinator.scheduleControlAction("interface-liquid-glass") {
                    await $0.setInterface(.liquidGlass(value))
                }
            }
            Picker(simulatorStrings.colorFilter, selection: $colorFilter) {
                ForEach(SimulatorInterfaceSetting.ColorFilter.allCases, id: \.rawValue) { filter in
                    Text(simulatorStrings.colorFilter(filter)).tag(filter)
                }
            }
            .onChange(of: colorFilter) { _, value in
                guard coordinator.interfaceStatus?.colorFilter != value else { return }
                coordinator.scheduleControlAction("interface-color-filter") {
                    await $0.setInterface(.colorFilter(value))
                }
            }
            interfaceToggle(
                simulatorStrings.reduceMotion,
                value: $reduceMotion,
                current: coordinator.interfaceStatus?.reduceMotion
            ) { .reduceMotion($0) }
            interfaceToggle(
                simulatorStrings.buttonShapes,
                value: $buttonShapes,
                current: coordinator.interfaceStatus?.buttonShapes
            ) { .buttonShapes($0) }
            interfaceToggle(
                simulatorStrings.reduceTransparency,
                value: $reduceTransparency,
                current: coordinator.interfaceStatus?.reduceTransparency
            ) { .reduceTransparency($0) }
            interfaceToggle(
                simulatorStrings.voiceOver,
                value: $voiceOver,
                current: coordinator.interfaceStatus?.voiceOver
            ) { .voiceOver($0) }
            Divider()
            TextField(String(localized: simulatorStrings.statusTime), text: $time)
            TextField(String(localized: simulatorStrings.carrier), text: $carrier)
            Picker(simulatorStrings.dataNetwork, selection: $dataNetwork) {
                ForEach(SimulatorStatusBarOverride.DataNetwork.allCases, id: \.rawValue) { value in
                    Text(simulatorStrings.dataNetwork(value)).tag(value)
                }
            }
            Picker(simulatorStrings.wifiMode, selection: $wifiMode) {
                ForEach(SimulatorStatusBarOverride.ConnectionMode.allCases, id: \.rawValue) { value in
                    Text(simulatorStrings.connection(value)).tag(value)
                }
            }
            LabeledContent(String(localized: simulatorStrings.wifiBars)) {
                Stepper(value: $wifiBars, in: 0...3) { Text(verbatim: "\(wifiBars)") }
            }
            Picker(simulatorStrings.cellularMode, selection: $cellularMode) {
                ForEach(SimulatorStatusBarOverride.CellularMode.allCases, id: \.rawValue) { value in
                    Text(simulatorStrings.cellular(value)).tag(value)
                }
            }
            LabeledContent(String(localized: simulatorStrings.cellularBars)) {
                Stepper(value: $cellularBars, in: 0...4) { Text(verbatim: "\(cellularBars)") }
            }
            Picker(simulatorStrings.batteryState, selection: $batteryState) {
                ForEach(SimulatorStatusBarOverride.BatteryState.allCases, id: \.rawValue) { value in
                    Text(simulatorStrings.battery(value)).tag(value)
                }
            }
            LabeledContent(String(localized: simulatorStrings.batteryLevel)) {
                Stepper(value: $battery, in: 0...100) { Text(verbatim: "\(battery)%") }
            }
            HStack {
                Button(simulatorStrings.applyStatusBar) {
                    coordinator.scheduleControlAction("status-bar") {
                        await $0.overrideStatusBar(SimulatorStatusBarOverride(
                            time: time,
                            dataNetwork: dataNetwork,
                            wifiMode: wifiMode,
                            wifiBars: wifiBars,
                            cellularMode: cellularMode,
                            cellularBars: cellularBars,
                            operatorName: carrier,
                            batteryState: batteryState,
                            batteryLevel: battery
                        ))
                    }
                }
                Button(simulatorStrings.clearStatusBar) {
                    coordinator.scheduleControlAction("status-bar") { await $0.clearStatusBar() }
                }
            }
        }
        .task {
            await coordinator.refreshInterfaceStatus()
            synchronize(from: coordinator.interfaceStatus)
        }
        .onChange(of: coordinator.interfaceStatus) { _, status in
            synchronize(from: status)
        }
    }

    private func interfaceToggle(
        _ title: LocalizedStringResource,
        value: Binding<Bool>,
        current: Bool? = nil,
        setting: @escaping @Sendable (Bool) -> SimulatorInterfaceSetting
    ) -> some View {
        Toggle(title, isOn: value)
            .onChange(of: value.wrappedValue) { _, enabled in
                guard current != enabled else { return }
                coordinator.scheduleControlAction("interface-\(String(describing: title))") {
                    await $0.setInterface(setting(enabled))
                }
            }
    }

    private func synchronize(from status: SimulatorInterfaceStatus?) {
        guard let status else { return }
        if let value = status.appearance { appearance = value }
        if let value = status.contentSize { contentSize = value }
        if let value = status.increaseContrast { increaseContrast = value }
        liquidGlass = status.liquidGlass
        colorFilter = status.colorFilter
        reduceMotion = status.reduceMotion
        buttonShapes = status.buttonShapes
        reduceTransparency = status.reduceTransparency
        voiceOver = status.voiceOver
    }
}
