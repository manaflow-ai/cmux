import Foundation

/// Host mode's part of `CEFRuntime.start` (``BrowserBackend/host``; task 015 of
/// plans/cmux-next/chrome-parity/p01-process.md): the supervisor's wire, the remote shim opened off
/// the main thread, attached, and the host's hello awaited. It never resolves the framework, builds
/// no `CEFLoadedLibrary` and starts no pump: Chromium's message loop runs in the host, as the GPU
/// process runs its own (content/gpu/gpu_main.cc) and the browser only holds a channel to it.
///
/// One attach per runtime: every concurrent first start awaits the same one.
final class CEFHostStart {
    /// Opens the remote dylib (off the main thread); ``CEFRemoteShim/open(_:)`` in the app.
    typealias Open = @Sendable (ChromiumHostAttachment) -> Result<CEFRemoteShim, CEFRuntime.BootError>

    private let supervisor: any ChromiumHostSupervising
    private let open: Open
    private var task: Task<Result<CEFAttachedHost, CEFRuntime.BootError>, Never>?

    init(supervisor: any ChromiumHostSupervising, open: @escaping Open = { CEFRemoteShim.open($0) }) {
        self.supervisor = supervisor
        self.open = open
    }

    /// The attached host; the first caller starts the attach, later ones await it.
    func attached() async -> Result<CEFAttachedHost, CEFRuntime.BootError> {
        if let task { return await task.value }
        let task = Task { [supervisor, open] in await CEFHostStart.attach(supervisor, open: open) }
        self.task = task
        return await task.value
    }

    private static func attach(_ supervisor: any ChromiumHostSupervising, open: @escaping Open) async -> Result<CEFAttachedHost, CEFRuntime.BootError> {
        let clock = ContinuousClock()
        let started = clock.now
        let attachment: ChromiumHostAttachment
        do { attachment = try await supervisor.attachment() } catch { return .failure(.host(error.description)) }
        // dlopen holds dyld's loader lock, so never on main; the in-process load beside it in CEFRuntime.start runs the same way.
        // qos-allow: the first Chromium tab waits for this one dlopen (userInitiated); nothing else runs in the task
        let opened = await Task.detached(priority: .userInitiated) { open(attachment) }.value
        let remote: CEFRemoteShim
        switch opened {
        case .success(let shim): remote = shim
        case .failure(let error):
            attachment.closeDescriptors()
            return .failure(error)
        }
        guard let hostExports = await remote.attach(attachment) else {
            return .failure(.host("the host ended before its hello"))
        }
        do {
            let shim = try CEFShimLibrary.resolving(remote.symbol, hostExports: hostExports)
            let locale = CEFLocale.resolve(preferredLanguages: Locale.preferredLanguages,
                                           available: CEFLocale.available(lprojNames: attachment.frameworkLocales))
            return .success(CEFAttachedHost(shim: shim, shimABI: CEFShimABI.bundledIdentity() ?? "", locale: locale,
                                            loadDuration: clock.now - started))
        } catch {
            return .failure(.shim(error))
        }
    }
}

/// The remote shim, attached to a host that said hello: host mode's counterpart of `CEFLoadedLibrary`.
nonisolated struct CEFAttachedHost: Sendable {
    var shim: CEFShimLibrary
    var shimABI: String
    /// UI locale and Accept-Language from the macOS preferred languages and the host's framework locales.
    var locale: CEFLocale
    /// From the supervisor's request to the host's hello.
    var loadDuration: Duration
}

/// What `CEFRuntime` initializes Chromium with: the in-process library or the attached host.
nonisolated enum CEFRuntimeBoot: Sendable {
    case inProcess(CEFLoadedLibrary)
    case host(CEFAttachedHost)

    var shim: CEFShimLibrary {
        switch self {
        case .inProcess(let library): library.shim
        case .host(let host): host.shim
        }
    }

    var shimABI: String {
        switch self {
        case .inProcess(let library): library.shimABI
        case .host(let host): host.shimABI
        }
    }

    var locale: CEFLocale {
        switch self {
        case .inProcess(let library): library.locale
        case .host(let host): host.locale
        }
    }

    var loadDuration: Duration {
        switch self {
        case .inProcess(let library): library.loadDuration
        case .host(let host): host.loadDuration
        }
    }

    /// `cmux_shim_initialize`'s framework, main bundle and helper paths. The host starts Chromium
    /// from its own launch arguments (`ChromiumHostConfiguration`), so host mode sends none.
    var chromiumPaths: (framework: String, mainBundle: String, helper: String) {
        switch self {
        case .inProcess(let library):
            (library.layout.frameworkDirectory.path, library.layout.mainBundle.path, library.layout.helperExecutable.path)
        case .host: ("", "", "")
        }
    }
}
