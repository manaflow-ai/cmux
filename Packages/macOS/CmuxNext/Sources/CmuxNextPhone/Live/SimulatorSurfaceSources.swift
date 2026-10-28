public import Foundation
import os

/// The phone's streamed simulator tabs (cmux-next-ios/verify/simulator-surface.md): one
/// ``SimulatorSurfaceServer`` per phone tab (`s<surface>`), started and stopped at hostd's
/// request. `device` names the phone a daemon surface's phone tab shows now (nil when the
/// surface is not an open phone tab of this app's daemon); the app supplies it from its store.
@MainActor
public final class SimulatorSurfaceSources {
    public enum Failure: Error, CustomStringConvertible {
        case notPhoneTab, noPhone

        public var description: String {
            switch self {
            case .notPhoneTab: "that tab is not a phone tab on this Mac"
            case .noPhone: "that phone tab shows no simulator"
            }
        }
    }

    private let phones: PhoneService
    private let device: @MainActor (UInt64) -> PhoneDeviceID??
    private var servers: [String: SimulatorSurfaceServer] = [:]
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "phone.surface")

    public init(phones: PhoneService, device: @escaping @MainActor (UInt64) -> PhoneDeviceID??) {
        self.phones = phones
        self.device = device
    }

    /// Whether this Mac may stream simulators: a SimulatorKit host and a selected Xcode. Loading
    /// SimulatorKit waits for the first stream, so launch never pays for it.
    public static func available(_ phones: PhoneService) -> Bool {
        phones.live != nil && FileManager.default.fileExists(atPath: SimulatorKitHID.selectedDeveloperDirectory())
    }

    /// `s<surface>` as a daemon surface number.
    public static func surface(of tab: String) -> UInt64? {
        guard tab.hasPrefix("s"), let raw = UInt64(tab.dropFirst()), String(raw) == tab.dropFirst() else { return nil }
        return raw
    }

    public func start(tab: String, onExit: @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String) {
        guard let surface = Self.surface(of: tab), let shown = device(surface) else { throw Failure.notPhoneTab }
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
        // The source can stop while it starts (its tab closed): never keep a dead one.
        guard server.isRunning else { throw Failure.notPhoneTab }
        servers[tab] = server
        logger.info("surface source for \(tab, privacy: .public) streams \(id.description, privacy: .public) on port \(port, privacy: .public)")
        return (port, server.secret)
    }

    public func stop(tab: String) {
        servers.removeValue(forKey: tab)?.stop()
    }

    public func stopAll() {
        let all = servers.values
        servers = [:]
        for server in all { server.stop() }
    }
}
