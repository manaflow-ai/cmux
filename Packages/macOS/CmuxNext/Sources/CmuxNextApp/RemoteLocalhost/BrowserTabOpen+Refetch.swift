import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextRemoteLocalhost
import CmuxNextRemoteLocalhostService
import Foundation

extension BrowserTabOpen {
    /// Asks the Cloud app server for `machine`'s browser route again (#25595): ``CloudBrowserRoute``
    /// calls it when the route a tab had is gone (the link dropped or was replaced) and on the first
    /// request of a tab restored after a relaunch. Only for a machine on the app server's link that
    /// runs: `cloud.browser.open` connects the link, which would start a paused machine, and a page
    /// must never do that. Each answer gets the checks of a page's request, for this machine.
    static func refetch(machine: String, name: String, services: AppServices) -> CloudBrowserRoute.Fetch {
        let ops = services.cloud.appOps
        return { [weak services] host, port in
            guard let services, await isRunning(machine, services: services) else {
                throw LoopbackTunnelFailure.unavailable("\(name) is not running")
            }
            let args: CmuxNextDaemon.JSONValue = .object(["machine": .string(machine), "port": .number(Double(port)), "host": .string(host)])
            let route = try await ops("cloud.browser.open", args, UUID().uuidString.lowercased(), .script)
            return try await answer(route, machine: machine, machineName: name)
        }
    }

    private static func isRunning(_ machine: String, services: AppServices) -> Bool {
        services.machines.cloud.contains { session in
            guard session.machineID == machine, session.appLink != nil else { return false }
            let connected = if case .connected = session.daemon.store.connectionState { true } else { false }
            return mayRefetch(live: session.machine.status.isLive, connected: connected)
        }
    }

    /// Whether a page may ask for its machine's route: the machine's record says it runs, or its
    /// daemon is connected (a click resumed it and the record still reads paused until the next
    /// list). Neither: the machine is paused or gone, and asking would start it.
    nonisolated static func mayRefetch(live: Bool, connected: Bool) -> Bool { live || connected }

    private static func answer(_ route: CmuxNextDaemon.JSONValue, machine: String, machineName: String) throws -> CloudBrowserRoute.Answer {
        let request = try request(route: pageJSON(route), machineName: machineName)
        guard request.machine == machine else { throw Refusal.proxyInvalid }
        return CloudBrowserRoute.Answer(proxyPort: request.proxyPort, credential: request.credential)
    }

    /// The store of a proxied tab restored after a relaunch (``ProxiedBrowserTabs/restore``): its
    /// machine's route is fetched on the page's first request, once the machine is listed, linked
    /// and running; until then the page shows the proxy's "not connected" page, which loads again
    /// when the machine connects (``StrandedPageReload``). Never this Mac's localhost.
    static func restoredStore(_ machine: ProxiedBrowserTabs.Machine, services: AppServices) async -> BrowserMachineStore? {
        try? await services.remoteLocalhost.restoredCloudBrowserStore(
            machineKey: machineKey(machine: machine.id), machineName: machine.name,
            fetch: refetch(machine: machine.id, name: machine.name, services: services))
    }
}
