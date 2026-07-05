import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Tests the pure `GET /api/devices` → device-tree model decode that backs the
/// hierarchical device tree (device → app instances/tags → routes). This is the
/// data contract the tree renders, so it must keep the registry's two-level
/// shape and the forward-compatible failable-per-route behavior.
@Suite struct DeviceRegistryListParsingTests {
    private static let sample = """
    {
      "teamId": "team-a",
      "devices": [
        {
          "deviceId": "AAAA1111-1111-4111-8111-111111111111",
          "platform": "mac",
          "displayName": "Lawrence's Mac",
          "lastSeenAt": "2026-06-08T10:00:00.000Z",
          "instances": [
            {
              "tag": "stable",
              "lastSeenAt": "2026-06-08T10:00:00.000Z",
              "routes": [
                { "id": "r1", "kind": "tailscale", "priority": 0,
                  "endpoint": { "type": "host_port", "host": "100.1.1.1", "port": 51001 } }
              ]
            },
            {
              "tag": "dog",
              "lastSeenAt": "2026-06-08T09:00:00.000Z",
              "routes": [
                { "id": "bad", "kind": "unknown_future_kind", "endpoint": { "type": "???" } },
                { "id": "r2", "kind": "tailscale", "priority": 0,
                  "endpoint": { "type": "host_port", "host": "100.2.2.2", "port": 51002 } }
              ]
            }
          ]
        },
        {
          "deviceId": "BBBB2222-2222-4222-8222-222222222222",
          "platform": "ios",
          "displayName": "Lawrence's iPhone",
          "lastSeenAt": "2026-06-08T08:00:00.000Z",
          "instances": []
        }
      ]
    }
    """.data(using: .utf8)!

    @Test func parsesTwoLevelDeviceTree() throws {
        let devices = try #require(DeviceRegistryService.parseDeviceList(in: Self.sample))
        #expect(devices.count == 2)

        let mac = try #require(devices.first { $0.platform == "mac" })
        #expect(mac.deviceId == "AAAA1111-1111-4111-8111-111111111111")
        #expect(mac.displayName == "Lawrence's Mac")
        #expect(mac.title == "Lawrence's Mac")
        #expect(mac.isControllableHost)
        // Two tagged app instances on the same device.
        #expect(mac.instances.count == 2)
        #expect(Set(mac.instances.map(\.tag)) == ["stable", "dog"])
    }

    @Test func malformedRouteIsDroppedNotFatal() throws {
        // The "dog" instance has one unknown-kind route and one good route: the
        // good one survives, the bad one is skipped (forward-compat contract).
        let devices = try #require(DeviceRegistryService.parseDeviceList(in: Self.sample))
        let mac = try #require(devices.first { $0.platform == "mac" })
        let dog = try #require(mac.instances.first { $0.tag == "dog" })
        #expect(dog.routes.count == 1)
        #expect(dog.routes.first?.id == "r2")
        #expect(dog.hasRoutes)
    }

    @Test func iosDeviceIsParsedButNotControllable() throws {
        // The phone-self row is parsed (so the count is honest) but is filtered as
        // a non-controllable host by the tree, never offered as a tappable target.
        let devices = try #require(DeviceRegistryService.parseDeviceList(in: Self.sample))
        let phone = try #require(devices.first { $0.platform == "ios" })
        #expect(!phone.isControllableHost)
        #expect(phone.instances.isEmpty)
    }

    @Test func lastSeenIsParsedFromISO8601() throws {
        let devices = try #require(DeviceRegistryService.parseDeviceList(in: Self.sample))
        let mac = try #require(devices.first { $0.platform == "mac" })
        // 2026-06-08T10:00:00Z is well after distantPast: a real timestamp parsed.
        #expect(mac.lastSeenAt > Date(timeIntervalSince1970: 1_700_000_000))
        let stable = try #require(mac.instances.first { $0.tag == "stable" })
        let dog = try #require(mac.instances.first { $0.tag == "dog" })
        #expect(stable.lastSeenAt > dog.lastSeenAt)
    }

    @Test func emptyTagDefaultsToDefault() throws {
        let json = """
        { "teamId": "t", "devices": [
          { "deviceId": "CCCC3333-3333-4333-8333-333333333333", "platform": "mac",
            "instances": [ { "routes": [] } ] }
        ] }
        """.data(using: .utf8)!
        let devices = try #require(DeviceRegistryService.parseDeviceList(in: json))
        #expect(devices.first?.instances.first?.tag == "default")
        #expect(devices.first?.instances.first?.hasRoutes == false)
    }

    @Test func malformedEnvelopeReturnsNil() {
        #expect(DeviceRegistryService.parseDeviceList(in: Data("not json".utf8)) == nil)
        #expect(DeviceRegistryService.parseDeviceList(in: Data("{}".utf8)) == nil)
    }

    @Test func deviceWithoutIdIsDropped() throws {
        let json = """
        { "teamId": "t", "devices": [
          { "deviceId": "  ", "platform": "mac", "instances": [] },
          { "deviceId": "DDDD4444-4444-4444-8444-444444444444", "platform": "mac", "instances": [] }
        ] }
        """.data(using: .utf8)!
        let devices = try #require(DeviceRegistryService.parseDeviceList(in: json))
        #expect(devices.count == 1)
        #expect(devices.first?.deviceId == "DDDD4444-4444-4444-8444-444444444444")
    }
}
