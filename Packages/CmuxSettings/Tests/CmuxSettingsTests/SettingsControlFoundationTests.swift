import Foundation
import Testing
@testable import CmuxSettings

/// Foundation-level checks for the settings control layer: the enum
/// allowed-values witness, descriptor reflection parity with the catalog, and
/// `SettingJSONValue` round-tripping. These guard the trickiest generics before
/// the engine is layered on top.
@Suite("SettingsControlFoundation")
struct SettingsControlFoundationTests {
    @Test func caseIterableEnumAdvertisesItsRawValues() {
        #expect(AppearanceMode.settingAllowedRawValues == ["system", "light", "dark"])
        #expect(SocketControlMode.settingAllowedRawValues == SocketControlMode.allCases.map(\.rawValue))
    }

    @Test func openValueTypesAdvertiseNoCases() {
        #expect(Bool.settingAllowedRawValues == nil)
        #expect(Int.settingAllowedRawValues == nil)
        #expect(String.settingAllowedRawValues == nil)
        #expect(Double.settingAllowedRawValues == nil)
    }

    @Test func descriptorsCoverExactlyTheCatalog() {
        let catalog = SettingCatalog()
        let keyIDs = Set(catalog.all.map(\.id))
        let descriptorIDs = Set(catalog.allDescriptors.map(\.id))
        #expect(descriptorIDs == keyIDs)
        // Reflection must not drop or duplicate entries.
        #expect(catalog.allDescriptors.count == catalog.all.count)
    }

    @Test func enumDescriptorReportsTypeAndCases() throws {
        let catalog = SettingCatalog()
        let descriptor = try #require(catalog.allDescriptors.first { $0.id == "app.appearance" })
        #expect(descriptor.backend == .userDefaults)
        #expect(descriptor.isSecret == false)
        #expect(descriptor.valueType == .enumeration(cases: ["system", "light", "dark"]))
        #expect(descriptor.defaultValue == .string("system"))
    }

    @Test func scalarDescriptorsReportScalarTypes() throws {
        let catalog = SettingCatalog()
        let portBase = try #require(catalog.allDescriptors.first { $0.id == "automation.portBase" })
        #expect(portBase.valueType == .int)
        #expect(portBase.defaultValue == .int(9100))

        let menuBarOnly = try #require(catalog.allDescriptors.first { $0.id == "app.menuBarOnly" })
        #expect(menuBarOnly.valueType == .bool)
        #expect(menuBarOnly.defaultValue == .bool(false))
    }

    @Test func secretDescriptorIsMarkedSecret() throws {
        let catalog = SettingCatalog()
        let secret = try #require(catalog.allDescriptors.first { $0.id == "automation.socketPassword" })
        #expect(secret.backend == .secret)
        #expect(secret.isSecret == true)
        #expect(secret.valueType == .string)
    }

    @Test func jsonValueRoundTripsThroughText() {
        let samples: [SettingJSONValue] = [
            .null,
            .bool(true),
            .int(42),
            .double(0.5),
            .string("dark"),
            .string("needs \"quotes\" and \n newline"),
            .array([.string("a"), .int(1)]),
            .object(["b": .string("y"), "a": .int(1)]),
        ]
        for sample in samples {
            let reparsed = SettingJSONValue.parseJSON(sample.jsonText)
            #expect(reparsed == sample, "round-trip failed for \(sample.jsonText)")
        }
        // Object text is canonical (keys sorted).
        #expect(SettingJSONValue.object(["b": .int(2), "a": .int(1)]).jsonText == "{\"a\":1,\"b\":2}")
    }

    @Test func parseJSONFallsBackToBareString() {
        #expect(SettingJSONValue.parseJSON("dark") == .string("dark"))
        #expect(SettingJSONValue.parseJSON("code -w") == .string("code -w"))
        #expect(SettingJSONValue.parseJSON("true") == .bool(true))
        #expect(SettingJSONValue.parseJSON("9100") == .int(9100))
    }
}
