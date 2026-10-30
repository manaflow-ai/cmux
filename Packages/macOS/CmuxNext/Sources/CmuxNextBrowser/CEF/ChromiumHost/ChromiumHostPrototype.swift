public import AppKit

/// The Chromium host app prototype as `debug.chromium_host` drives it
/// (DEBUG builds, `browserHost.helperPrototype` on): one
/// ``ChromiumHostSession`` shown over a pane's content view.
/// plans/cmux-next/cef-helper-app-DESIGN.md.
@MainActor
public final class ChromiumHostPrototype {
    private var session: ChromiumHostSession?
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

    /// `debug.chromium_host` {op: open {url, pane?, focus?} | close | kill | report}:
    /// `container` is the pane content view `open` shows the page over.
    public func handle(op: String?, url: String?, over container: NSView?, focus: Bool) -> [String: Any] {
        switch op {
        case "open":
            guard let container else { return ["error": "no pane"] }
            return open(url ?? "", over: container, focus: focus)
        case "close": return close()
        case "kill": return kill()
        default: return report
        }
    }

    /// `debug.chromium_host.measure` {op: ping {count} | input}; nil without a running host.
    public func measure(op: String?, count: Int?) async -> [String: Double]? {
        op == "ping" ? await ping(count: count ?? 200) : await inputStats()
    }

    /// Starts the host (or navigates it) and shows its page over `container`,
    /// first responder of `window` when `focus`.
    public func open(_ url: String, over container: NSView, focus: Bool) -> [String: Any] {
        guard BrowserHostTunables.helperPrototype.value else { return ["error": "browserHost.helperPrototype is off"] }
        guard !url.isEmpty else { return ["error": "pass url"] }
        let session: ChromiumHostSession
        if let existing = self.session {
            session = existing
        } else {
            guard let configuration = makeConfiguration() else {
                return ["error": "this build has no Chromium host app (Debug builds with CEF only)"]
            }
            session = ChromiumHostSession(configuration: configuration)
            self.session = session
        }
        if session.view.superview !== container {
            session.view.removeFromSuperview()
            session.view.frame = container.bounds
            container.addSubview(session.view, positioned: .above, relativeTo: nil)
        }
        session.open(url)
        if focus { container.window?.makeFirstResponder(session.view) }
        return report
    }

    /// Ends the host on purpose and removes its page view.
    public func close() -> [String: Any] {
        session?.close()
        session?.view.removeFromSuperview()
        return report
    }

    /// SIGKILL to the host (the crash check).
    public func kill() -> [String: Any] {
        ["killed_pid": Int(session?.killHost() ?? 0)]
    }

    public var report: [String: Any] {
        var fields = session?.report ?? ["phase": "none"]
        fields["tunable"] = BrowserHostTunables.helperPrototype.value
        fields["app_pid"] = Int(ProcessInfo.processInfo.processIdentifier)
        return fields
    }

    /// `count` wire round trips to the host's UI thread, as microsecond
    /// percentiles; nil without a running host.
    public func ping(count: Int) async -> [String: Double]? {
        guard let session else { return nil }
        let samples = await session.ping(count: min(max(count, 1), 10_000)).sorted()
        guard let last = samples.last else { return nil }
        func at(_ q: Double) -> Double { samples[Int((q * Double(samples.count - 1)).rounded())] }
        return ["count": Double(samples.count), "p50_us": at(0.5), "p95_us": at(0.95), "p99_us": at(0.99), "max_us": last]
    }

    /// The host's event-time-to-dispatch percentiles; nil without a running host.
    public func inputStats() async -> [String: Double]? {
        guard let stats = await session?.hostInputStats() else { return nil }
        return stats.mapValues(Double.init)
    }
}
