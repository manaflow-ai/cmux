import CmuxNextDaemon
import CmuxNextMobile
import CmuxNextPhone

/// hostd's `need_surface` for this app: ``SimulatorSurfaceSources`` (CmuxNextPhone) over the
/// phone tabs of the app's own daemon store.
final class PhoneSurfaceHosts: MobileHostSurfaceHosting {
    private let sources: SimulatorSurfaceSources

    @MainActor init(_ sources: SimulatorSurfaceSources) { self.sources = sources }

    func start(tab: String, onExit: @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String) {
        try await sources.start(tab: tab, onExit: onExit)
    }

    func stop(tab: String) async { await sources.stop(tab: tab) }
    func stopAll() async { await sources.stopAll() }
}

extension AppServices {
    /// The phone tabs of this app's own daemon as streamed simulator surfaces; nil when it cannot stream them.
    func phoneSurfaceHosts() -> (any MobileHostSurfaceHosting)? {
        guard SimulatorSurfaceSources.available(phones) else { return nil }
        return PhoneSurfaceHosts(SimulatorSurfaceSources(phones: phones) { [weak self] raw in
            guard let self, let tab = self.daemon.store.tab(surface: SurfaceID(rawValue: raw)),
                  tab.page == InternalPageID.phone.rawValue else { return nil }
            let key = self.pages.storeKey(of: tab.id)
            let route = key.flatMap { (self.pages.provider(.phone) as? PhonePageTab)?.route(for: $0) } ?? tab.pageRoute
            return .some(route.flatMap { PhoneDeviceID($0) })
        })
    }
}
