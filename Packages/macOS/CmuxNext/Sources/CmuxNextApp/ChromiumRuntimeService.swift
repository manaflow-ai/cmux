import CmuxNextBrowser
import CmuxNextChromiumRuntime
import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// Chromium on demand (plans/cmux-next/bundle-size-DESIGN.md section 6): the
/// app build ships without the CEF runtime and a pin
/// (`Contents/Resources/cef-runtime.json`) names the pack to download.
///
/// At launch ``make(work:bundle:environment:applicationSupport:hostSupervisor:sanitizer:)`` picks the
/// runtime: the embedded one (builds that still bundle CEF), the pinned pack
/// when it is installed, or an older compatible pack while the pinned one
/// downloads. With none, tabs open in WebKit and the ``source`` reports
/// `downloading` until the install finishes; then the next Chromium tab
/// starts Chromium, in this process or, with a host supervisor, in the
/// Chromium Host (``backend``).
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
        /// Off in a sanitizer build (``SanitizerRuntime``): neither the embedded runtime nor a pack loads.
        case sanitizer
    }

    /// The runtime ``CEFEngine`` reads.
    let source: CEFRuntimeSource
    /// Where Chromium's browser process runs, fixed for the process: App code that
    /// reaches Chromium's page windows does so only for ``BrowserBackend/inProcess``.
    var backend: BrowserBackend { source.backend }
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
    /// The background download's one-shot start after launch (made by ``start(on:)``).
    private var prefetch: MainDeadline?

    /// Creates the service.
    ///
    /// - Parameters:
    ///   - source: The runtime source for ``CEFEngine``.
    ///   - origin: Which runtime the launch picked.
    ///   - installer: Installs the pinned pack; nil when there is nothing to download.
    ///   - mainBundle: The app bundle, the main bundle for a runtime outside an `.app`.
    ///   - prefetchDelay: How long after ``start(on:)`` the background download begins.
    init(source: CEFRuntimeSource, origin: Origin, installer: ChromiumRuntimeInstaller?, mainBundle: URL,
         downloadedTrust: CEFRuntimeLayout.Trust? = nil, prefetchDelay: Duration = .seconds(20)) {
        self.source = source
        self.origin = origin
        self.installer = installer
        pinnedKey = installer?.pin.key
        self.mainBundle = mainBundle
        self.downloadedTrust = downloadedTrust
        self.prefetchDelay = prefetchDelay
    }

    /// The service for this app: none in a sanitizer build that did not ask
    /// for Chromium, else the embedded runtime when present, else the bundled
    /// pin with the URLSession, tar, code-signature and path-monitor
    /// implementations. `work` is the app's one ``BackgroundWork``: the
    /// code-signature checks run on its system lane. `hostSupervisor` puts
    /// Chromium in the Chromium Host (``BrowserBackend/host``); nil keeps it
    /// in this process.
    ///
    /// - Parameter sanitizer: The process's sanitizer runtime; nil detects it from `environment`.
    static func make(work: BackgroundWork, bundle: Bundle = .main,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     applicationSupport: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                     hostSupervisor: (any ChromiumHostSupervising)? = nil,
                     sanitizer: SanitizerRuntime? = nil)
        -> ChromiumRuntimeService {
        guard (sanitizer ?? SanitizerRuntime.detect(environment: environment)).loadsChromium else {
            return ChromiumRuntimeService(source: CEFRuntimeSource(layout: nil), origin: .sanitizer, installer: nil, mainBundle: bundle.bundleURL)
        }
        if let layout = CEFRuntimeLayout.locate(bundle: bundle, environment: environment) {
            return ChromiumRuntimeService(source: CEFRuntimeSource(layout: layout, hostSupervisor: hostSupervisor), origin: .bundled,
                                          installer: nil, mainBundle: bundle.bundleURL)
        }
        guard let resources = bundle.resourceURL, let pin = ChromiumRuntimePin.bundled(in: resources),
              let bundleID = bundle.bundleIdentifier, let applicationSupport else {
            return ChromiumRuntimeService(source: CEFRuntimeSource(layout: nil, hostSupervisor: hostSupervisor), origin: .none,
                                          installer: nil, mainBundle: bundle.bundleURL)
        }
        let store = ChromiumRuntimeStore(root: ChromiumRuntimeStore.defaultRoot(applicationSupport: applicationSupport, bundleIdentifier: bundleID))
        return launch(pin: pin, store: store, mainBundle: bundle.bundleURL, hostSupervisor: hostSupervisor) { inUse in
            ChromiumRuntimeInstaller(pin: pin, store: store, downloader: URLSessionChromiumRuntimeDownloader(),
                                     unpacker: TarChromiumRuntimeUnpacker(),
                                     signatures: SecCodeChromiumRuntimeSignatureChecker(work: work) {
                                         StaticCodeValidityCache.process.isValid($0, flags: $1, requirement: $2)
                                     },
                                     network: PathMonitorChromiumRuntimeNetwork(), keepAlso: { inUse })
        }
    }

    /// Picks the launch runtime for `pin` from `store`, and the installer
    /// (`makeInstaller` receives the pack keys this process may run, which
    /// cleanup must keep), with Chromium in the Chromium Host when
    /// `hostSupervisor` is given.
    static func launch(pin: ChromiumRuntimePin, store: ChromiumRuntimeStore, mainBundle: URL, prefetchDelay: Duration = .seconds(20),
                       hostSupervisor: (any ChromiumHostSupervising)? = nil,
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
        let source = CEFRuntimeSource(layout: layout, pending: .downloading(fraction: nil), hostSupervisor: hostSupervisor)
        return ChromiumRuntimeService(source: source, origin: origin, installer: makeInstaller(inUse), mainBundle: mainBundle,
                                      downloadedTrust: trust, prefetchDelay: prefetchDelay)
    }

    /// Follows the installer and schedules the background download (or, when
    /// the pinned pack is already installed, the cleanup of older packs).
    ///
    /// - Parameter deadlines: The app's deadline scheduler: each installer state applies as a
    ///   `visible` task on its scheduler, and the prefetch delay is a `background` deadline.
    func start(on deadlines: MainDeadlineScheduler) {
        guard let installer, tasks.isEmpty, prefetch == nil else { return }
        // task-owner: lives with the service (one per process); cancelled in stop(). The stream is read off main;
        // each state is one posted `visible` task: a tab that waits for Chromium shows the download's progress.
        tasks.append(Task { @concurrent [weak self, mainWork = deadlines.work] in
            for await state in await installer.states() {
                guard let service = self else { return }
                mainWork.postFromAnyThread(.visible, owner: "chromium-runtime.state") { service.apply(state) }
            }
        })
        // A one-shot launch delay so the prefetch does not compete with launch work; one hop to the installer actor,
        // whose ensure returns at once (task-owner).
        prefetch = MainDeadline(owner: "chromium-runtime.prefetch", workClass: .background, scheduler: deadlines)
        prefetch?.schedule(after: prefetchDelay) { Task { @concurrent in await installer.ensure(.background) } }
    }

    /// A tab wanted Chromium: download now at user priority (any network).
    /// Cheap and idempotent; does nothing once a runtime is in use.
    func wanted() {
        guard let installer, source.layout == nil else { return }
        // task-owner: one hop to the installer actor; ensure returns at once
        Task { @concurrent in await installer.ensure(.user) }
    }

    /// Stops following the installer (app quit).
    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        prefetch?.cancel()
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
