import Foundation

extension SimulatorStrings {
    var routeTrail: LocalizedStringResource {
        simulatorResource("simulator.location.trail", "Trail")
    }

    var routeCustom: LocalizedStringResource {
        simulatorResource("simulator.location.custom", "Custom Route")
    }

    var transportMode: LocalizedStringResource {
        simulatorResource("simulator.location.transport", "Transport")
    }

    var speedMultiplier: LocalizedStringResource {
        simulatorResource("simulator.location.speedMultiplier", "Speed")
    }

    func name(for mode: SimulatorLocationTransportMode) -> LocalizedStringResource {
        switch mode {
        case .walk: simulatorResource("simulator.location.mode.walk", "Walk")
        case .run: simulatorResource("simulator.location.mode.run", "Run")
        case .cycle: simulatorResource("simulator.location.mode.cycle", "Cycle")
        case .drive: simulatorResource("simulator.location.mode.drive", "Drive")
        }
    }

    func name(for preset: SimulatorLocationPreset) -> LocalizedStringResource {
        switch preset {
        case .applePark: simulatorResource("simulator.location.preset.applePark", "Apple Park Loop")
        case .goldenGate: simulatorResource("simulator.location.preset.goldenGate", "Golden Gate Crossing")
        case .mountTam: simulatorResource("simulator.location.preset.mountTam", "Mt. Tam Ridge")
        case .centralPark: simulatorResource("simulator.location.preset.centralPark", "Reservoir Loop")
        case .pacificCoast: simulatorResource("simulator.location.preset.pacificCoast", "Pacific Coast Hwy")
        }
    }

    func description(for preset: SimulatorLocationPreset) -> LocalizedStringResource {
        switch preset {
        case .applePark:
            simulatorResource("simulator.location.preset.applePark.description", "Cupertino • flat ring road")
        case .goldenGate:
            simulatorResource("simulator.location.preset.goldenGate.description", "San Francisco • bridge round-trip")
        case .mountTam:
            simulatorResource(
                "simulator.location.preset.mountTam.description",
                "Stinson Beach • Steep Ravine + Matt Davis loop"
            )
        case .centralPark:
            simulatorResource("simulator.location.preset.centralPark.description", "Central Park • 2.5 km")
        case .pacificCoast:
            simulatorResource(
                "simulator.location.preset.pacificCoast.description",
                "Pacifica • Devil's Slide round-trip"
            )
        }
    }
}
