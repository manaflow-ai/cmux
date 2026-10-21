import CmuxNextMobile
import CmuxNextRemoteBrowser
import Foundation

/// The phone's streamed browser tabs run on this app's own remote browser
/// host (`Contents/Helpers/cmux-remote-browser-host.app`, the CEF host its
/// remote browser tabs use), one ``LocalRemoteBrowserHost`` per phone tab,
/// started and stopped at hostd's request (cmux-next-ios/verify/browser-stream.md).
/// Every configuration bundles the host (arm64 only); each host listens on loopback
/// with its own secret, and only cmux-mobile-host reaches it (cmux-next-ios/SECURITY.md, `browser`).
final class IPhoneBrowserHosts: MobileHostBrowserHosting {
    enum Failure: Error { case noHost }

    private let registry = Registry()
    private let workRoot: URL

    init(workRoot: URL) {
        self.workRoot = workRoot
    }

    /// Whether this Mac can run the bundled host: it is arm64 only, so an Intel Mac
    /// (and a build without it) refuses phone browser tabs and hostd says no
    /// `browser-stream-v1`.
    static func available() -> Bool {
        #if arch(arm64)
        LocalRemoteBrowserHostLocator().executable() != nil
        #else
        false
        #endif
    }

    func start(tab: String, url: String, onExit: @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String) {
        try await registry.start(tab: tab, url: url, workRoot: workRoot, onExit: onExit)
    }

    func stop(tab: String) async { await registry.stop(tab: tab) }

    func stopAll() async { await registry.stopAll() }

    @MainActor
    private final class Registry {
        var hosts: [String: LocalRemoteBrowserHost] = [:]

        func start(tab: String, url: String, workRoot: URL, onExit: @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String) {
            guard let executable = LocalRemoteBrowserHostLocator().executable() else { throw Failure.noHost }
            hosts.removeValue(forKey: tab)?.stop()
            try? FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
            let host = try await LocalRemoteBrowserHost.start(executable: executable, pageURL: URL(string: url), workRoot: workRoot)
            hosts[tab] = host
            // task-owner: one per host; ends when the host exits
            Task { @MainActor [weak self] in
                _ = await host.exitStatus()
                if self?.hosts[tab] === host { self?.hosts[tab] = nil }
                onExit()
            }
            return (host.endpoint.port, host.secret)
        }

        func stop(tab: String) {
            hosts.removeValue(forKey: tab)?.stop()
        }

        func stopAll() {
            for host in hosts.values { host.stop() }
            hosts = [:]
        }
    }
}
