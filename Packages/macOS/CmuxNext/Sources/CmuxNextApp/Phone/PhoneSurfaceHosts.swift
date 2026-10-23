import CmuxNextDaemon
import CmuxNextMobile
import CmuxNextPhone
import Foundation
import os

/// The phone streams this Mac's phone tabs (cmux-next-ios/verify/simulator-surface.md):
/// for hostd's `need_surface {tab}` it checks that `tab` (`s<surface>`) is a phone
/// tab in this app's own daemon now, finds the simulator that tab shows, and
/// starts a ``SimulatorSurfaceServer`` for it on loopback. A tab of another
/// kind, a tab no longer open, or a phone that is not a booted simulator is refused.
final class PhoneSurfaceHosts: MobileHostSurfaceHosting {
    enum Failure: Error, CustomStringConvertible {
        case notPhoneTab, noPhone

        var description: String {
            switch self {
            case .notPhoneTab: "that tab is not a phone tab on this Mac"
            case .noPhone: "that phone tab shows no simulator"
            }
        }
    }

    private let registry: Registry

    /// - Parameter device: the phone a phone tab (`s<surface>`) shows now; nil when
    ///   the surface is not an open phone tab of this app's daemon.
    @MainActor
    init(phones: PhoneService, device: @escaping @MainActor (SurfaceID) -> PhoneDeviceID??) {
        registry = Registry(phones: phones, device: device)
    }

    /// Whether this Mac may stream simulators: the app has a SimulatorKit host and an Xcode
    /// is selected. Loading SimulatorKit waits for the first stream (``SimulatorSurfaceServer``
    /// refuses it with a reason when this Xcode gives no live screen), so launch never pays for it.
    @MainActor
    static func available(_ phones: PhoneService) -> Bool {
        phones.live != nil && FileManager.default.fileExists(atPath: SimulatorKitHID.selectedDeveloperDirectory())
    }

    func start(tab: String, onExit: @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String) {
        try await registry.start(tab: tab, onExit: onExit)
    }

    func stop(tab: String) async { await registry.stop(tab: tab) }

    func stopAll() async { await registry.stopAll() }

    /// `s<surface>` as a daemon surface.
    static func surface(of tab: String) -> SurfaceID? {
        guard tab.hasPrefix("s"), let raw = UInt64(tab.dropFirst()), String(raw) == tab.dropFirst() else { return nil }
        return SurfaceID(rawValue: raw)
    }

    @MainActor
    private final class Registry {
        let phones: PhoneService
        let device: @MainActor (SurfaceID) -> PhoneDeviceID??
        var servers: [String: SimulatorSurfaceServer] = [:]

        init(phones: PhoneService, device: @escaping @MainActor (SurfaceID) -> PhoneDeviceID??) {
            self.phones = phones
            self.device = device
        }

        func start(tab: String, onExit: @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String) {
            guard let surface = PhoneSurfaceHosts.surface(of: tab), let shown = device(surface) else { throw Failure.notPhoneTab }
            guard let id = shown else { throw Failure.noPhone }
            servers.removeValue(forKey: tab)?.stop()
            let server = SimulatorSurfaceServer(service: phones, device: id)
            // The tab closed or now shows another phone: the source stops (and hostd hears surface_gone).
            let device = device
            server.stillShown = { device(surface) == .some(id) }
            server.onEnd = { [weak self, weak server] in
                if let server, self?.servers[tab] === server { self?.servers[tab] = nil }
                onExit()
            }
            let port = try await server.start()
            servers[tab] = server
            Logger(subsystem: "com.cmuxterm.app.next", category: "phone.surface")
                .info("surface source for \(tab, privacy: .public) streams \(id.description, privacy: .public) on port \(port, privacy: .public)")
            return (port, server.secret)
        }

        func stop(tab: String) {
            servers.removeValue(forKey: tab)?.stop()
        }

        func stopAll() {
            let all = servers.values
            servers = [:]
            for server in all { server.stop() }
        }
    }
}

extension PhonePageTab {
    /// The phone that store tab `tab` shows: its open view's, else its saved route.
    func device(showing tab: TabModel, key: String?) -> PhoneDeviceID? {
        if let key, let route = route(for: key), let id = PhoneDeviceID(route) { return id }
        return tab.pageRoute.flatMap { PhoneDeviceID($0) }
    }
}

extension AppServices {
    /// The phone tabs of this app's own daemon as streamed simulator surfaces, or nil
    /// when this Xcode gives no live simulator screen (hostd then offers none).
    func phoneSurfaceHosts() -> (any MobileHostSurfaceHosting)? {
        guard PhoneSurfaceHosts.available(phones) else { return nil }
        return PhoneSurfaceHosts(phones: phones) { [weak self] surface in
            guard let self, let tab = self.daemon.store.tab(surface: surface),
                  tab.page == InternalPageID.phone.rawValue else { return nil }
            let page = self.pages.provider(.phone) as? PhonePageTab
            return .some(page?.device(showing: tab, key: self.pages.storeKey(of: tab.id)) ?? tab.pageRoute.flatMap { PhoneDeviceID($0) })
        }
    }
}
