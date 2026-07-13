import CMUXMobileCore
@testable import CmuxMobileShell

actor StaticReconnectDeviceRegistry: DeviceRegistryRefreshing {
    let routes: [CmxAttachRoute]

    init(routes: [CmxAttachRoute]) {
        self.routes = routes
    }

    func freshRoutes(
        forMacDeviceID _: String,
        instanceTag _: String?
    ) async -> [CmxAttachRoute]? {
        routes
    }

    func listDevices() async -> DeviceRegistryListOutcome {
        .transientFailure
    }
}
