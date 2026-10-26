import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextRemoteLocalhost
import CmuxNextRemoteLocalhostService
import Foundation

extension BrowserTabOpen {
    /// Asks the Cloud app server for `machine`'s browser route again (#25595): ``CloudBrowserRoute``
    /// calls it when the route a tab had is gone (the link dropped or was replaced) and on the first
    /// request of a tab restored after a relaunch. Each answer gets the checks of a page's request.
    static func refetch(machine: String, name: String, services: AppServices) -> CloudBrowserRoute.Fetch {
        let ops = services.cloud.appOps
        return { host, port in
            let args: CmuxNextDaemon.JSONValue = .object(["machine": .string(machine), "port": .number(Double(port)), "host": .string(host)])
            let route = try await ops("cloud.browser.open", args, UUID().uuidString.lowercased(), .script)
            return try await answer(route, machineName: name)
        }
    }

    private static func answer(_ route: CmuxNextDaemon.JSONValue, machineName: String) throws -> CloudBrowserRoute.Answer {
        let request = try request(route: pageJSON(route), machineName: machineName)
        return CloudBrowserRoute.Answer(proxyPort: request.proxyPort, credential: request.credential)
    }

    /// The store of a proxied tab restored after a relaunch (``ProxiedBrowserTabs/restore``): its
    /// machine's route is fetched on the page's first request. Nil when the machine is gone or not on
    /// the Cloud app server's link; the tab then stays blank, never on this Mac's localhost.
    static func restoredStore(_ machine: ProxiedBrowserTabs.Machine, services: AppServices) async -> BrowserMachineStore? {
        guard services.machines.cloud.contains(where: { $0.machineID == machine.id && $0.appLink != nil }) else { return nil }
        return try? await services.remoteLocalhost.restoredCloudBrowserStore(
            machineKey: machineKey(machine: machine.id), machineName: machine.name,
            fetch: refetch(machine: machine.id, name: machine.name, services: services))
    }
}
