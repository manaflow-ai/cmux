public import AppKit

/// The Chromium host app prototype as `debug.chromium_host` drives it
/// (DEBUG builds, `browserHost.helperPrototype` on): one
/// ``ChromiumHostSession`` per pane, shown over the pane's content view.
/// plans/cmux-next/cef-helper-app-DESIGN.md.
///
/// `remote: true` (fork API 37, in-tree pages approach 4) starts the host in remote Cocoa mode: the page's own
/// Chromium views are made in cmux's window by the remote_cocoa bridges (``ChromiumRemoteCocoaClient``); otherwise
/// the host's layer-hosted pixels and forwarded input (API 26).
@MainActor
public final class ChromiumHostPrototype {
    /// One session per pane key (`"default"` when the call names none). Each host has its own data folder.
    private var sessions: [String: ChromiumHostSession] = [:]
    private var order: [String] = []
    private let makeConfiguration: () -> ChromiumHostConfiguration?

    /// - Parameter makeConfiguration: the host app of this build, or nil when it has none.
    public init(makeConfiguration: @escaping () -> ChromiumHostConfiguration?) {
        self.makeConfiguration = makeConfiguration
    }

    /// The bundled host of this app (`<App> Chromium Host.app`), its data under
    /// `<Application Support>/<bundle id>/ChromiumHost`.
    public static func bundledConfiguration(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment,
                                            fileManager: FileManager = .default) -> ChromiumHostConfiguration? {
        guard let layout = CEFRuntimeLayout.locate(bundle: bundle, environment: environment, fileManager: fileManager),
              let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let identifier = bundle.bundleIdentifier ?? "cmux"
        return ChromiumHostConfiguration.bundled(in: layout, rootCache: support.appending(path: identifier).appending(path: "ChromiumHost"),
                                                 bundleIdentifier: identifier, environment: environment, fileManager: fileManager)
    }

    /// `debug.chromium_host` {op: open {url, pane?, focus?, remote?} | close {pane?} | kill {pane?} | focus {pane?} |
    /// report {pane?} | list}: `container` is the pane content view `open` shows the page over, `key` the session's.
    public func handle(op: String?, url: String?, over container: NSView?, key: String?, focus: Bool, remote: Bool) -> [String: Any] {
        let key = key ?? "default"
        switch op {
        case "open":
            guard let container else { return ["error": "no pane"] }
            return open(url ?? "", over: container, key: key, focus: focus, remote: remote)
        case "close": return close(key)
        case "kill": return kill(key)
        case "focus":
            guard let session = sessions[key] else { return ["error": "no session \(key)"] }
            if session.remoteCocoa { session.focusRemotePage() } else { session.view.window?.makeFirstResponder(session.view) }
            return report(key)
        case "list":
            return ["sessions": order.map { report($0) }, "app_pid": Int(ProcessInfo.processInfo.processIdentifier)]
        default: return report(key)
        }
    }

    /// `debug.chromium_host.measure` {op: ping {count} | input, pane?}; nil without a running host.
    public func measure(op: String?, count: Int?, key: String?) async -> [String: Double]? {
        guard let session = sessions[key ?? "default"] ?? order.first.flatMap({ sessions[$0] }) else { return nil }
        return op == "ping" ? await ping(session, count: count ?? 200) : await inputStats(session)
    }

    /// Starts the host (or navigates it) and shows its page over `container`,
    /// first responder of `window` when `focus`.
    public func open(_ url: String, over container: NSView, key: String, focus: Bool, remote: Bool) -> [String: Any] {
        guard BrowserHostTunables.helperPrototype.value else { return ["error": "browserHost.helperPrototype is off"] }
        guard !url.isEmpty else { return ["error": "pass url"] }
        let session: ChromiumHostSession
        if let existing = sessions[key] {
            session = existing
        } else {
            guard let configuration = makeConfiguration() else {
                return ["error": "this build has no Chromium host app (Debug builds with CEF only)"]
            }
            // The first session keeps the old data folder; later ones get their own (one browser process each).
            let suffix = order.isEmpty ? nil : "\(order.count)"
            session = ChromiumHostSession(configuration: configuration.variant(suffix: suffix, remoteCocoa: remote), remoteCocoa: remote)
            sessions[key] = session
            order.append(key)
        }
        if session.view.superview !== container {
            session.view.removeFromSuperview()
            session.view.frame = container.bounds
            container.addSubview(session.view, positioned: .above, relativeTo: nil)
        }
        session.open(url)
        if focus {
            if session.remoteCocoa { session.focusRemotePage() } else { container.window?.makeFirstResponder(session.view) }
        }
        return report(key)
    }

    /// Ends the host on purpose and removes its page view.
    public func close(_ key: String) -> [String: Any] {
        let session = sessions[key]
        session?.close()
        session?.view.removeFromSuperview()
        return report(key)
    }

    /// SIGKILL to the host (the crash check).
    public func kill(_ key: String) -> [String: Any] {
        ["killed_pid": Int(sessions[key]?.killHost() ?? 0)]
    }

    public func report(_ key: String) -> [String: Any] {
        var fields = sessions[key]?.report ?? ["phase": "none"]
        fields["key"] = key
        fields["tunable"] = BrowserHostTunables.helperPrototype.value
        fields["app_pid"] = Int(ProcessInfo.processInfo.processIdentifier)
        return fields
    }

    /// `count` wire round trips to the host's UI thread, as microsecond
    /// percentiles; nil without a running host.
    private func ping(_ session: ChromiumHostSession, count: Int) async -> [String: Double]? {
        let samples = await session.ping(count: min(max(count, 1), 10_000)).sorted()
        guard let last = samples.last else { return nil }
        func at(_ q: Double) -> Double { samples[Int((q * Double(samples.count - 1)).rounded())] }
        return ["count": Double(samples.count), "p50_us": at(0.5), "p95_us": at(0.95), "p99_us": at(0.99), "max_us": last]
    }

    /// The host's event-time-to-dispatch percentiles; nil without a running host.
    private func inputStats(_ session: ChromiumHostSession) async -> [String: Double]? {
        guard let stats = await session.hostInputStats() else { return nil }
        return stats.mapValues(Double.init)
    }
}
