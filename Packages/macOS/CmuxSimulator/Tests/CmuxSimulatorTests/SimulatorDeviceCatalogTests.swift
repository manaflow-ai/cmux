import Foundation
import Testing
@testable import CmuxSimulator

@Suite("SimulatorDeviceCatalog")
struct SimulatorDeviceCatalogTests {
    @Test func parsesDevicesAcrossRuntimesAndSkipsMalformedUDIDs() throws {
        let catalog = try SimulatorDeviceCatalog(simctlListJSON: SimulatorFixtures.listDevices)
        #expect(catalog.devices.count == 3)
        #expect(!catalog.devices.contains(where: { $0.name == "Corrupt Device" }))

        let bootedUDID = try #require(SimulatorDeviceUDID(rawValue: SimulatorFixtures.bootedUDID))
        let booted = try #require(catalog.device(withUDID: bootedUDID))
        #expect(booted.name == "iPhone 17 Pro")
        #expect(booted.state == .booted)
        #expect(booted.isAvailable)
        #expect(booted.runtimeIdentifier == "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
        #expect(booted.deviceTypeIdentifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
        #expect(booted.runtimeDisplayName == "iOS 26.5")
    }

    @Test func parsesStateStrings() throws {
        #expect(SimulatorDeviceState(simctlState: "Shutdown") == .shutdown)
        #expect(SimulatorDeviceState(simctlState: "Booted") == .booted)
        #expect(SimulatorDeviceState(simctlState: "Booting") == .booting)
        #expect(SimulatorDeviceState(simctlState: "Shutting Down") == .shuttingDown)
        #expect(SimulatorDeviceState(simctlState: "Creating") == .creating)
        #expect(SimulatorDeviceState(simctlState: "Warp Drive") == .unknown("Warp Drive"))
    }

    @Test func missingIsAvailableDefaultsToUnavailable() throws {
        let json = Data("""
        {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
            {"udid": "\(SimulatorFixtures.shutdownUDID)", "state": "Shutdown", "name": "Mystery"}
        ]}}
        """.utf8)
        let catalog = try SimulatorDeviceCatalog(simctlListJSON: json)
        #expect(catalog.devices.count == 1)
        #expect(catalog.devices[0].isAvailable == false)
    }

    @Test func malformedJSONThrowsCatalogError() {
        #expect(throws: SimulatorCatalogError.self) {
            _ = try SimulatorDeviceCatalog(simctlListJSON: Data("not json".utf8))
        }
        #expect(throws: SimulatorCatalogError.self) {
            _ = try SimulatorDeviceCatalog(simctlListJSON: Data("{\"runtimes\": []}".utf8))
        }
    }

    @Test func queryMatchingPrefersUDIDThenBootedThenAvailable() throws {
        let catalog = try SimulatorDeviceCatalog(simctlListJSON: SimulatorFixtures.listDevices)

        let byUDID = try #require(catalog.device(matching: " \(SimulatorFixtures.shutdownUDID.lowercased()) "))
        #expect(byUDID.udid.rawValue == SimulatorFixtures.shutdownUDID)

        // Two devices share the name; the booted one wins.
        let byName = try #require(catalog.device(matching: "iphone 17 pro"))
        #expect(byName.udid.rawValue == SimulatorFixtures.bootedUDID)

        #expect(catalog.device(matching: "iPhone 42") == nil)
    }

    @Test func udidRejectsAliasesAndCanonicalizesCase() {
        #expect(SimulatorDeviceUDID(rawValue: "booted") == nil)
        #expect(SimulatorDeviceUDID(rawValue: "") == nil)
        #expect(SimulatorDeviceUDID(rawValue: "all") == nil)
        let canonical = SimulatorDeviceUDID(rawValue: SimulatorFixtures.bootedUDID.lowercased())
        #expect(canonical?.rawValue == SimulatorFixtures.bootedUDID)
    }

    @Test func sortedForDisplayPutsBootedFirst() throws {
        let catalog = try SimulatorDeviceCatalog(simctlListJSON: SimulatorFixtures.listDevices)
        let sorted = catalog.sortedForDisplay
        #expect(sorted.first?.state == .booted)
        #expect(sorted.last?.isAvailable == false)
    }
}
