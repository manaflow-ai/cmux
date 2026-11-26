import CmuxNextBrowser
import CmuxNextChromiumRuntime
import CmuxNextWakeups
import Foundation

/// Chromium on demand (plans/cmux-next/bundle-size-DESIGN.md section 6): the
/// app build ships without the CEF runtime and a pin
/// (`Contents/Resources/cef-runtime.json`) names the pack to download.
///
/// At launch ``make(bundle:environment:applicationSupport:)`` picks the
/// runtime: the embedded one (builds that still bundle CEF), the pinned pack
/// when it is installed, or an older compatible pack while the pinned one
/// downloads. With none, tabs open in WebKit and the ``source`` reports
/// `downloading` until the install finishes; then the next Chromium tab
/// starts Chromium in this process.
///
/// The download starts in the background ``prefetchDelay`` after launch (on
/// an unmetered network), or at once at user priority when a tab wants
/// Chromium (``wanted()``).
@MainActor
final class ChromiumRuntimeService {
    /// Which runtime the launch picked.
    enum Origin: String {
        /// Embedded in the app bundle (or `CMUX_NEXT_CEF_RUNTIME`).
        case bundled
        /// The pinned pack, installed.
        case installed
        /// An older pack with the same shim ABI, while the pinned one downloads.
        case compatible
        /// None yet: the pinned pack downloads.
        case downloading
        /// No runtime and no pin (fleet and CI builds).
        case none
    }

    /// The runtime ``CEFEngine`` reads.
    let source: CEFRuntimeSource
    /// Which runtime the launch picked.
    let origin: Origin
    /// The pinned pack's key, nil without a pin.
    let pinnedKey: String?
    /// The last installer state (`debug.cef`).
    private(set) var state: ChromiumRuntimeInstallState = .idle
    private let installer: ChromiumRuntimeInstaller?
    private let mainBundle: URL
    /// Load-time trust for an installed pack. Nil only for a bundled runtime
    /// or a build without a runtime pin.
    private let downloadedTrust: CEFRuntimeLayout.Trust?
    private let prefetchDelay: Duration
    private var tasks: [Task<Void, Never>] = []
    /// The background download's one-shot start after launch.
    private let prefetch: DemandTimer

    /// Creates the service.
    ///
    /// - Parameters:
    ///   - source: The runtime source for ``CEFEngine``.
    ///   - origin: Which runtime the launch picked.
    ///   - installer: Installs the pinned pack; nil when there is nothing to download.
    ///   - mainBundle: The app bundle, the main bundle for a runtime outside an `.app`.
    ///   - clock: Drives the prefetch delay; tests pass a clock they control.
    ///   - prefetchDelay: How long after ``start()`` the background download begins.
    init(source: CEFRuntimeSource, origin: Origin, installer: ChromiumRuntimeInstaller?, mainBundle: URL,
         downloadedTrust: CEFRuntimeLayout.Trust? = nil,
         clock: any Clock<Duration> = ContinuousClock(), prefetchDelay: Duration = .seconds(20)) {
        self.source = source
        self.origin = origin
        self.installer = installer
        pinnedKey = installer?.pin.key
        self.mainBundle = mainBundle
        self.downloadedTrust = downloadedTrust
        self.prefetchDelay = prefetchDelay
        prefetch = DemandTimer(owner: "chromium-runtime.prefetch", clock: clock)
    }

    /// The service for this app: the embedded runtime when present, else the
    /// bundled pin with the URLSession, tar, code-signature and path-monitor
    /// implementations.
    static func make(bundle: Bundle = .main,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     applicationSupport: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        -> ChromiumRuntimeService {
        if let layout = CEFRuntimeLayout.locate(bundle: bundle, environment: environment) {
            return ChromiumRuntimeService(source: CEFRuntimeSource(layout: layout), origin: .bundled, installer: nil, mainBundle: bundle.bundleURL)
        }
        guard let resources = bundle.resourceURL, let pin = ChromiumRuntimePin.bundled(in: resources),
              let bundleID = bundle.bundleIdentifier, let applicationSupport else {
            return ChromiumRuntimeService(source: CEFRuntimeSource(layout: nil), origin: .none, installer: nil, mainBundle: bundle.bundleURL)
        }
        let store = ChromiumRuntimeStore(root: ChromiumRuntimeStore.defaultRoot(applicationSupport: applicationSupport, bundleIdentifier: bundleID))
        return launch(pin: pin, store: store, mainBundle: bundle.bundleURL) { inUse in
            ChromiumRuntimeInstaller(pin: pin, store: store, downloader: URLSessionChromiumRuntimeDownloader(),
                                     unpacker: TarChromiumRuntimeUnpacker(), signatures: SecCodeChromiumRuntimeSignatureChecker(),
                                     network: PathMonitorChromiumRuntimeNetwork(), keepAlso: { inUse })
        }
    }

    /// Picks the launch runtime for `pin` from `store`, and the installer
    /// (`makeInstaller` receives the pack keys this process may run, which
    /// cleanup must keep).
    static func launch(pin: ChromiumRuntimePin, store: ChromiumRuntimeStore, mainBundle: URL,
                       clock: any Clock<Duration> = ContinuousClock(), prefetchDelay: Duration = .seconds(20),
                       makeInstaller: (Set<String>) -> ChromiumRuntimeInstaller) -> ChromiumRuntimeService {
        let selection = store.select(for: pin)
        let trust = CEFRuntimeLayout.Trust.downloaded(teamID: pin.teamID)
        let layout = selection.installation.flatMap {
            CEFRuntimeLayout.at($0.frameworksDirectory, fallbackMainBundle: mainBundle, trust: trust)
        }
        let origin: Origin
        switch selection {
        case .exact where layout != nil: origin = .installed
        case .compatible where layout != nil: origin = .compatible
        default: origin = .downloading
        }
        let inUse: Set<String> = layout == nil ? [] : Set(selection.installation.map { [$0.pin.key] } ?? [])
        let source = CEFRuntimeSource(layout: layout, pending: .downloading(fraction: nil))
        return ChromiumRuntimeService(source: source, origin: origin, installer: makeInstaller(inUse), mainBundle: mainBundle,
                                      downloadedTrust: trust,
                                      clock: clock, prefetchDelay: prefetchDelay)
    }

    /// Follows the installer and schedules the background download (or, when
    /// the pinned pack is already installed, the cleanup of older packs).
    func start() {
        guard let installer, tasks.isEmpty, !prefetch.isScheduled else { return }
        // task-owner: lives with the service (one per process); cancelled in stop()
        tasks.append(Task { [weak self] in
            for await state in await installer.states() {
                self?.apply(state)
            }
        })
        // A one-shot launch delay so the prefetch does not compete with launch work.
        prefetch.schedule(after: prefetchDelay) { await installer.ensure(.background) }
    }

    /// A tab wanted Chromium: download now at user priority (any network).
    /// Cheap and idempotent; does nothing once a runtime is in use.
    func wanted() {
        guard let installer, source.layout == nil else { return }
        // task-owner: one hop to the installer actor; ensure returns at once
        Task { await installer.ensure(.user) }
    }

    /// Stops following the installer (app quit).
    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        prefetch.cancel()
    }

    /// Maps one installer state onto ``source``.
    func apply(_ state: ChromiumRuntimeInstallState) {
        self.state = state
        switch state {
        case .idle, .waitingForNetwork, .verifying, .installing:
            source.update(pending: .downloading(fraction: nil))
        case .downloading:
            source.update(pending: .downloading(fraction: state.fraction))
        case .failed(let error, _):
            source.update(pending: .downloadFailed("\(error.code): \(error.detail)"))
        case .installed(let installation):
            let trust = downloadedTrust ?? .downloaded(teamID: nil)
            if let layout = CEFRuntimeLayout.at(installation.frameworksDirectory, fallbackMainBundle: mainBundle, trust: trust) {
                source.install(layout)
            } else {
                source.update(pending: .downloadFailed("missing: \(installation.frameworksDirectory.path)"))
            }
        }
    }
}
