import CmuxNextSettings
import Foundation
import Testing

/// cmux.json `deviceHub.url`: a DEV build's override of its built-in device hub address.
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

    @Test func eachBuildKindHasABuiltInHub() {
        #expect(DeviceHubSettings.builtInBaseURL(isDebugBuild: true) == URL(string: "https://cmux-device-hub-dev.debussy.workers.dev"))
        #expect(DeviceHubSettings.builtInBaseURL(isDebugBuild: false) == URL(string: "https://cmux-device-hub.debussy.workers.dev"))
        #expect(DeviceHubSettings().resolvedBaseURL(isDebugBuild: true) == DeviceHubSettings.builtInBaseURL(isDebugBuild: true))
        #expect(DeviceHubSettings().resolvedBaseURL(isDebugBuild: false) == DeviceHubSettings.builtInBaseURL(isDebugBuild: false))
    }

    @Test func anEmptyOverrideFallsBackToTheBuiltInHub() {
        var settings = DeviceHubSettings()
        for text in ["", "   ", "\n"] {
            settings.url = text
            #expect(settings.resolvedBaseURL(isDebugBuild: true) == URL(string: "https://cmux-device-hub-dev.debussy.workers.dev"), "\(text)")
        }
    }

    @Test func aDEVOverrideWinsAndReleaseBuildsIgnoreIt() {
        var settings = DeviceHubSettings()
        settings.url = " http://mini.tail.ts.net:8799 "
        #expect(settings.resolvedBaseURL(isDebugBuild: true) == URL(string: "http://mini.tail.ts.net:8799"))
        #expect(settings.resolvedBaseURL(isDebugBuild: false) == URL(string: "https://cmux-device-hub.debussy.workers.dev"))
        // An address that is not an http(s) URL with a host turns a DEV build's hub off, so the mistake shows.
        settings.url = "hub.example"
        #expect(settings.resolvedBaseURL(isDebugBuild: true) == nil)
        #expect(settings.resolvedBaseURL(isDebugBuild: false) == URL(string: "https://cmux-device-hub.debussy.workers.dev"))
    }

    @Test func theRowIsADevelopmentURLOnlyThePersonSets() throws {
        let row = try #require(SettingsSchema.all.first { $0.id == "deviceHub.url" })
        #expect(row.section == .development)
        #expect(row.kind == .url)
    }
}
