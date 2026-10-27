import Darwin
public import Foundation

/// What `CEFRuntime.start` asks for in host mode (``BrowserBackend/host``):
/// the Chromium Host's wire. The supervisor (`ChromiumHostSupervisor`, task 080
/// of plans/cmux-next/chrome-parity/p01-process.md) starts the one host off the
/// main thread, owns its restarts and hands out the client end of its
/// channel, as Chrome's `GpuProcessHost` starts the GPU process and
/// `BrowserGpuChannelHostFactory` hands the browser its `GpuChannelHost`
/// (content/browser/gpu/browser_gpu_channel_host_factory.cc).
public protocol ChromiumHostSupervising: AnyObject {
    /// Starts the host when none runs and returns its wire once the host
    /// connected. Never blocks the main thread. The caller owns the
    /// descriptors of the attachment it gets.
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment

    /// Runs `ended` on the main thread each time a host this supervisor started ends (a crash, a
    /// kill, a quit), before a restarted host attaches: what cmux showed of that host (its widgets)
    /// goes with it, as Chrome's browser drops a dead GPU process's state when
    /// `GpuProcessHost::OnProcessCrashed` runs (content/browser/gpu/gpu_process_host.cc).
    func observeHostEnds(_ ended: @escaping @MainActor () -> Void)
}

/// One host's wire, as the supervisor hands it to the runtime.
public nonisolated struct ChromiumHostAttachment: Sendable, Equatable {
    /// The control channel's socket (task 012).
    public var controlFD: Int32
    /// The input ring's descriptor, -1 while the host has none (task 041).
    public var inputRingFD: Int32
    /// The host's output ring's descriptor, -1 while the host has none.
    public var outputRingFD: Int32
    /// `libcmux_cef_shim_remote.dylib`, the remote shim that speaks this wire
    /// (task 014); it ships with the host.
    public var remoteShim: URL
    /// The `.lproj` folder names of the host's framework resources: the
    /// locales Chromium can show, which the app picks the UI locale from
    /// without listing the framework itself.
    public var frameworkLocales: [String]
    /// The bootstrap name of the host's resize fence inbox (the spawn's `--resize-fence=` argument,
    /// `ChromiumHostResizeFenceChannel`, task 052); nil for a host spawned without one.
    public var resizeFence: String?
    /// Where the remote shim mints ids for a host this cmux adopted from a crashed one (task p01-process-150): above
    /// every id that cmux minted there. Nil for a host this cmux started.
    public var mintFloor: ChromiumHostMintFloor?
    /// The pages an adopted host kept that this cmux's restored tabs take back, by their tab keys (task
    /// p01-process-150); empty for a host this cmux started.
    public var adoptedPages: [ChromiumHostAdoptedPage]

    public init(controlFD: Int32, inputRingFD: Int32 = -1, outputRingFD: Int32 = -1, remoteShim: URL,
                frameworkLocales: [String], resizeFence: String? = nil, mintFloor: ChromiumHostMintFloor? = nil,
                adoptedPages: [ChromiumHostAdoptedPage] = []) {
        self.controlFD = controlFD
        self.inputRingFD = inputRingFD
        self.outputRingFD = outputRingFD
        self.remoteShim = remoteShim
        self.frameworkLocales = frameworkLocales
        self.resizeFence = resizeFence
        self.mintFloor = mintFloor
        self.adoptedPages = adoptedPages
    }

    /// Closes every descriptor: the remote shim did not take them.
    func closeDescriptors() {
        for fd in [controlFD, inputRingFD, outputRingFD] where fd >= 0 {
            Darwin.close(fd)
        }
    }
}

/// The first ids a cmux may mint in a host it adopted (`cmux_remote_shim_set_mint_floor`; the host's
/// `HostContext::mint_floor`, task p01-process-150).
public nonisolated struct ChromiumHostMintFloor: Sendable, Equatable {
    /// The first browser id (create_window, tab_add, tab_duplicate).
    public var browser: Int32
    /// The first DevTools message id.
    public var devtools: Int32
    /// The first page view token (`CEFRuntime.mintPageViewToken`): above every token the crashed cmux sent.
    public var view: UInt64

    public init(browser: Int32, devtools: Int32, view: UInt64 = 1) {
        self.browser = browser
        self.devtools = devtools
        self.view = view
    }
}

/// A page an adopted host kept (task p01-process-150; the host's `adoption::AdoptedPage`): an open tab whose key the
/// crashed cmux sent. The relaunched cmux's restored tab of that key shows this page instead of creating one, so the
/// page is never reloaded.
public nonisolated struct ChromiumHostAdoptedPage: Sendable, Equatable {
    /// The client browser id the crashed cmux minted.
    public var browser: Int32
    /// Its Chromium window (`cmux_shim_tab_window_id`).
    public var window: Int32
    /// The page view token of its window's parent view, 0 for none.
    public var view: UInt64
    /// The Core Animation context its page window shows in, 0 when it was not layer hosted.
    public var context: UInt32
    /// The tab's key (its `BrowserTabID`).
    public var key: String

    public init(browser: Int32, window: Int32, view: UInt64, context: UInt32, key: String) {
        self.browser = browser
        self.window = window
        self.view = view
        self.context = context
        self.key = key
    }
}

/// Why the supervisor has no wire to hand out.
public nonisolated enum ChromiumHostAttachError: Error, Equatable, CustomStringConvertible {
    /// The host could not start, or ended before it connected (the reason).
    case cannotStart(String)

    public var description: String {
        switch self {
        case .cannotStart(let reason): "Chromium Host cannot start: \(reason)"
        }
    }
}
