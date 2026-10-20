import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShell

@Suite struct TaggedBuildRegistryRouteIsolationTests {
    @Test func tagBRegistryRestartCannotRedirectTagA() throws {
        let initial = try registryData(
            tagA: routeJSON(id: "a", host: "100.64.0.1", port: 51_001),
            tagB: routeJSON(id: "b", host: "100.64.0.2", port: 51_002)
        )
        let routeA = try #require(DeviceRegistryService.routes(
            forMacDeviceID: "shared-physical-mac",
            pairedMacInstanceTag: "feature-a",
            in: initial
        ))
        #expect(routeA.map(\.id) == ["a"])
        #expect(DeviceRegistryService.routes(
            forMacDeviceID: "shared-physical-mac",
            in: initial
        ) == nil)

        let afterBRestart = try registryData(
            tagA: routeJSON(id: "a", host: "100.64.0.1", port: 51_001),
            tagB: routeJSON(id: "b-restart", host: "100.64.0.3", port: 52_002)
        )
        let routeAAfterBRestart = try #require(DeviceRegistryService.routes(
            forMacDeviceID: "shared-physical-mac",
            pairedMacInstanceTag: "feature-a",
            in: afterBRestart
        ))
        #expect(routeAAfterBRestart.map(\.id) == ["a"])
        #expect(DeviceRegistryService.routes(
            forMacDeviceID: "shared-physical-mac",
            pairedMacInstanceTag: "missing",
            in: afterBRestart
        ) == nil)
    }

    @Test func officialIOSReadsOnlyRequestedStableMacRoutes() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "devices": [[
                "deviceId": "shared-physical-mac",
                "instances": [
                    [
                        "tag": "default",
                        "routes": routeJSON(id: "stable", host: "100.64.0.1", port: 51_001),
                    ],
                    [
                        "tag": "feature-b",
                        "routes": routeJSON(id: "b", host: "100.64.0.2", port: 51_002),
                    ],
                ],
            ]],
        ])

        let routes = try #require(DeviceRegistryService.routes(
            forMacDeviceID: "shared-physical-mac",
            pairedMacInstanceTag: "default",
            in: data
        ))
        #expect(routes.map(\.id) == ["stable"])
        #expect(DeviceRegistryService.routes(
            forMacDeviceID: "shared-physical-mac",
            pairedMacInstanceTag: "feature-a",
            in: data
        ) == nil)
    }

    @Test func unscopedRegistryKeepsSoleInstanceFallback() throws {
        let data = try registryData(
            tagA: [],
            tagB: routeJSON(id: "b", host: "100.64.0.2", port: 51_002)
        )
        let routes = try #require(DeviceRegistryService.routes(
            forMacDeviceID: "shared-physical-mac",
            in: data
        ))
        #expect(routes.map(\.id) == ["b"])
    }

    private func registryData(tagA: Any, tagB: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "devices": [[
                "deviceId": "shared-physical-mac",
                "instances": [
                    ["tag": "feature-a", "routes": tagA],
                    ["tag": "feature-b", "routes": tagB],
                ],
            ]],
        ])
    }

    private func routeJSON(id: String, host: String, port: Int) -> [[String: Any]] {
        [[
            "id": id,
            "kind": "tailscale",
            "endpoint": ["type": "host_port", "host": host, "port": port],
            "priority": 0,
        ]]
    }
}
