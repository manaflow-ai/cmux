import CmuxSimulator
import SwiftUI

struct SimulatorLocationTools: View {
    let coordinator: SimulatorPaneCoordinator
    @State private var latitude = "37.3349"
    @State private var longitude = "-122.0090"
    @State private var destinationLatitude = "37.3317"
    @State private var destinationLongitude = "-122.0307"
    @State private var presetID: String? = SimulatorLocationPreset.applePark.rawValue
    @State private var mode: SimulatorLocationTransportMode = .walk
    @State private var multiplier = 1

    var body: some View {
        SimulatorToolSection(simulatorStrings.location) {
            coordinateFields
            HStack {
                Button(simulatorStrings.setLocation) {
                    guard let coordinate = coordinate(latitude: latitude, longitude: longitude) else { return }
                    coordinator.scheduleControlAction("set-location") { await $0.setLocation(coordinate) }
                }
                Button(simulatorStrings.clearLocation) {
                    coordinator.scheduleControlAction("set-location") { await $0.clearLocation() }
                }
            }
            Divider()
            Picker(String(localized: simulatorStrings.routeTrail), selection: $presetID) {
                Text(simulatorStrings.routeCustom).tag(String?.none)
                ForEach(SimulatorLocationPreset.allCases) { preset in
                    Text(simulatorStrings.name(for: preset)).tag(Optional(preset.rawValue))
                }
            }
            if let preset = selectedPreset {
                Text(simulatorStrings.description(for: preset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField(
                    String(localized: simulatorStrings.destinationLatitude),
                    text: $destinationLatitude
                )
                TextField(
                    String(localized: simulatorStrings.destinationLongitude),
                    text: $destinationLongitude
                )
            }
            Picker(String(localized: simulatorStrings.transportMode), selection: $mode) {
                ForEach(SimulatorLocationTransportMode.allCases) { mode in
                    Text(simulatorStrings.name(for: mode)).tag(mode)
                }
            }
            Picker(String(localized: simulatorStrings.speedMultiplier), selection: $multiplier) {
                ForEach([1, 2, 5, 20], id: \.self) { value in
                    Text(verbatim: "\(value)×").tag(value)
                }
            }
            Button(simulatorStrings.startRoute) {
                guard let waypoints = selectedRouteWaypoints else { return }
                coordinator.scheduleControlAction("location-route") {
                    await $0.startLocationRoute(SimulatorLocationRoute(
                        waypoints: waypoints,
                        speed: mode.metersPerSecond * Double(multiplier),
                        loops: selectedPreset != nil
                    ))
                }
            }
            if coordinator.locationRouteIsActive {
                HStack {
                    if coordinator.locationRouteIsPaused {
                        Button(simulatorStrings.resumeRoute) {
                            coordinator.scheduleControlAction("location-route") {
                                await $0.resumeLocationRoute()
                            }
                        }
                    } else {
                        Button(simulatorStrings.pauseRoute) {
                            coordinator.scheduleControlAction("location-route") {
                                await $0.pauseLocationRoute()
                            }
                        }
                    }
                    Button(simulatorStrings.stopRoute, role: .destructive) {
                        coordinator.scheduleControlAction("location-route") {
                            await $0.stopLocationRoute()
                        }
                    }
                }
            }
        }
        .onChange(of: presetID) { _, _ in
            if let preset = selectedPreset { mode = preset.defaultMode }
        }
    }

    private var coordinateFields: some View {
        HStack {
            TextField(String(localized: simulatorStrings.latitude), text: $latitude)
            TextField(String(localized: simulatorStrings.longitude), text: $longitude)
        }
    }

    private func coordinate(latitude: String, longitude: String) -> SimulatorLocationCoordinate? {
        guard let latitude = Double(latitude), (-90...90).contains(latitude),
              let longitude = Double(longitude), (-180...180).contains(longitude) else { return nil }
        return SimulatorLocationCoordinate(latitude: latitude, longitude: longitude)
    }

    private var selectedPreset: SimulatorLocationPreset? {
        presetID.flatMap(SimulatorLocationPreset.init(rawValue:))
    }

    private var selectedRouteWaypoints: [SimulatorLocationCoordinate]? {
        if let selectedPreset { return selectedPreset.closedWaypoints }
        guard let start = coordinate(latitude: latitude, longitude: longitude),
              let destination = coordinate(
                  latitude: destinationLatitude,
                  longitude: destinationLongitude
              ) else { return nil }
        return [start, destination]
    }
}
