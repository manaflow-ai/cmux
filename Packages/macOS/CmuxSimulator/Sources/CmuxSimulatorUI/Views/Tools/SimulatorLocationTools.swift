import AppKit
import CmuxSimulator

@MainActor
final class SimulatorLocationTools: SimulatorToolSection, SimulatorToolsSection {
    private let coordinator: SimulatorPaneCoordinator
    private let latitude = SimulatorClosureTextField(value: "37.3349")
    private let longitude = SimulatorClosureTextField(value: "-122.0090")
    private let destinationLatitude = SimulatorClosureTextField(value: "37.3317")
    private let destinationLongitude = SimulatorClosureTextField(value: "-122.0307")
    private let presetPicker = SimulatorClosurePopUpButton()
    private let presetDescription = simulatorLabel("", color: .secondaryLabelColor)
    private let destinationRow: NSStackView
    private let modePicker = SimulatorClosurePopUpButton()
    private let multiplierPicker = SimulatorClosurePopUpButton()
    private let pauseResumeButton = SimulatorClosureButton()
    private let stopButton = SimulatorClosureButton(title: String(localized: simulatorStrings.stopRoute))
    private let presets = [SimulatorLocationPreset?](arrayLiteral: nil) + SimulatorLocationPreset.allCases
    private let modes = SimulatorLocationTransportMode.allCases
    private let multipliers = [1, 2, 5, 20]

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
        latitude.placeholderString = String(localized: simulatorStrings.latitude)
        longitude.placeholderString = String(localized: simulatorStrings.longitude)
        destinationLatitude.placeholderString = String(localized: simulatorStrings.destinationLatitude)
        destinationLongitude.placeholderString = String(localized: simulatorStrings.destinationLongitude)
        destinationRow = simulatorRow([destinationLatitude, destinationLongitude])
        super.init(simulatorStrings.location)
        add(simulatorRow([latitude, longitude]))
        let set = SimulatorClosureButton(title: String(localized: simulatorStrings.setLocation)) {
            [weak self] in self?.setLocation()
        }
        let clear = SimulatorClosureButton(title: String(localized: simulatorStrings.clearLocation)) {
            [weak coordinator] in
            coordinator?.scheduleControlAction("set-location") { await $0.clearLocation() }
        }
        add(simulatorRow([set, clear]))
        presetPicker.addItems(withTitles: presets.map { preset in
            preset.map { String(localized: simulatorStrings.name(for: $0)) }
                ?? String(localized: simulatorStrings.routeCustom)
        })
        presetPicker.selectItem(at: 1)
        presetPicker.handler = { [weak self] _ in self?.presetChanged() }
        add(presetPicker)
        add(presetDescription)
        add(destinationRow)
        modePicker.addItems(withTitles: modes.map { String(localized: simulatorStrings.name(for: $0)) })
        multiplierPicker.addItems(withTitles: multipliers.map { "\($0)×" })
        add(simulatorRow([modePicker, multiplierPicker]))
        let start = SimulatorClosureButton(title: String(localized: simulatorStrings.startRoute)) {
            [weak self] in self?.startRoute()
        }
        pauseResumeButton.handler = { [weak self] in self?.pauseOrResume() }
        stopButton.contentTintColor = .systemRed
        stopButton.handler = { [weak coordinator] in
            coordinator?.scheduleControlAction("location-route") { await $0.stopLocationRoute() }
        }
        add(start)
        add(simulatorRow([pauseResumeButton, stopButton]))
        presetChanged()
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update() {
        let active = coordinator.locationRouteIsActive
        pauseResumeButton.isHidden = !active
        stopButton.isHidden = !active
        pauseResumeButton.title = String(localized: coordinator.locationRouteIsPaused
            ? simulatorStrings.resumeRoute
            : simulatorStrings.pauseRoute)
    }

    private func presetChanged() {
        let preset = selectedPreset
        presetDescription.stringValue = preset.map {
            String(localized: simulatorStrings.description(for: $0))
        } ?? ""
        presetDescription.isHidden = preset == nil
        destinationRow.isHidden = preset != nil
        if let preset, let index = modes.firstIndex(of: preset.defaultMode) {
            modePicker.selectItem(at: index)
        }
    }

    private func setLocation() {
        guard let coordinate = coordinate(latitude: latitude.stringValue, longitude: longitude.stringValue) else {
            return
        }
        coordinator.scheduleControlAction("set-location") { await $0.setLocation(coordinate) }
    }

    private func startRoute() {
        guard let waypoints = selectedRouteWaypoints,
              modes.indices.contains(modePicker.indexOfSelectedItem),
              multipliers.indices.contains(multiplierPicker.indexOfSelectedItem) else { return }
        let route = SimulatorLocationRoute(
            waypoints: waypoints,
            speed: modes[modePicker.indexOfSelectedItem].metersPerSecond
                * Double(multipliers[multiplierPicker.indexOfSelectedItem]),
            loops: selectedPreset != nil
        )
        coordinator.scheduleControlAction("location-route") { await $0.startLocationRoute(route) }
    }

    private func pauseOrResume() {
        if coordinator.locationRouteIsPaused {
            coordinator.scheduleControlAction("location-route") { await $0.resumeLocationRoute() }
        } else {
            coordinator.scheduleControlAction("location-route") { await $0.pauseLocationRoute() }
        }
    }

    private var selectedPreset: SimulatorLocationPreset? {
        guard presets.indices.contains(presetPicker.indexOfSelectedItem) else { return nil }
        return presets[presetPicker.indexOfSelectedItem]
    }

    private var selectedRouteWaypoints: [SimulatorLocationCoordinate]? {
        if let selectedPreset { return selectedPreset.closedWaypoints }
        guard let start = coordinate(latitude: latitude.stringValue, longitude: longitude.stringValue),
              let destination = coordinate(
                  latitude: destinationLatitude.stringValue,
                  longitude: destinationLongitude.stringValue
              ) else { return nil }
        return [start, destination]
    }

    private func coordinate(latitude: String, longitude: String) -> SimulatorLocationCoordinate? {
        guard let latitude = Double(latitude), (-90...90).contains(latitude),
              let longitude = Double(longitude), (-180...180).contains(longitude) else { return nil }
        return SimulatorLocationCoordinate(latitude: latitude, longitude: longitude)
    }
}
