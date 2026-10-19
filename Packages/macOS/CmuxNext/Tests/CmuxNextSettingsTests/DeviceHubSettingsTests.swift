import CmuxNextSettings
import Foundation
import Testing

/// cmux.json `deviceHub.url`: the device hub address DEV builds sign their devices in to.
struct DeviceHubSettingsTests {
    @Test func theURLIsReadAndEmptyMeansOff() throws {
        let snapshot = CmuxConfigSnapshot.parse(try JSONValue.parse(Data(#"{"deviceHub":{"url":"http://mini.tail.ts.net:8787"}}"#.utf8)),
                                                validDensities: [], validMetrics: [])
        #expect(snapshot.deviceHub.url == "http://mini.tail.ts.net:8787")
        #expect(snapshot.deviceHub.baseURL == URL(string: "http://mini.tail.ts.net:8787"))
        #expect(CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: []).deviceHub.baseURL == nil)
    }

    @Test func onlyHTTPAddressesWithAHostTurnItOn() {
        var settings = DeviceHubSettings()
        for (text, on) in [("", false), ("  ", false), ("ftp://hub", false), ("hub.example", false), ("https://", false),
                           (" https://hub.example ", true), ("https://hub.example/base", true)] {
            settings.url = text
            #expect((settings.baseURL != nil) == on, "\(text)")
        }
    }

    @Test func theRowIsADevelopmentURLOnlyThePersonSets() throws {
        let row = try #require(SettingsSchema.all.first { $0.id == "deviceHub.url" })
        #expect(row.section == .development)
        #expect(row.kind == .url)
    }
}
