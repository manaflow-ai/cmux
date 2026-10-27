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

    /// The host whose wire is `attachment` said hello (its Chromium context is initialized, CONTEXT_INITIALIZED).
    /// Only after it does an end count as a crash of the restart budget; a host that dies before it could not start,
    /// as Chrome's GPU process that failed to initialize (`did_fail_initialize_`, content/browser/gpu/gpu_process_host.cc).
    func hostSaidHello(_ attachment: ChromiumHostAttachment)

    /// cmux ends its running host on purpose (quit, an app update, a Chromium runtime update; task 087 of
    /// plans/cmux-next/chrome-parity/p01-process.md): the host was told to quit (its wire closed), and this returns
    /// once it is gone, SIGKILLing it at `limit`. Its end spends no crash and shows no page a crash state. Chrome's
    /// browser ends every child process before it exits (`BrowserChildProcessHostImpl::TerminateAll`,
    /// content/browser/browser_child_process_host_impl.cc): a host left running would still hold the app bundle Sparkle
    /// replaces and its data folder, which the next host needs.
    func endHost(within limit: Duration) async

    /// The Chromium runtime the next host starts from (``CEFRuntimeSource``'s, as it is picked or updated). A running
    /// host keeps its own; the ``observeRuntimeChanges(_:)`` observers hear of a change while one runs.
    func runtimeChanged(_ layout: CEFRuntimeLayout)

    /// Runs `changed` on the main thread when ``runtimeChanged(_:)`` gives a runtime while a host runs on another one.
    func observeRuntimeChanges(_ changed: @escaping @MainActor () -> Void)
}

extension ChromiumHostSupervising {
    /// A supervisor with no restart budget does not tell its hosts apart by their hello.
    public func hostSaidHello(_ attachment: ChromiumHostAttachment) {}

    /// A supervisor that starts no process has nothing to end.
    public func endHost(within limit: Duration) async {}

    /// A supervisor that starts its hosts from one runtime ignores another.
    public func runtimeChanged(_ layout: CEFRuntimeLayout) {}

    public func observeRuntimeChanges(_ changed: @escaping @MainActor () -> Void) {}
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

    public init(controlFD: Int32, inputRingFD: Int32 = -1, outputRingFD: Int32 = -1, remoteShim: URL,
                frameworkLocales: [String], resizeFence: String? = nil) {
        self.controlFD = controlFD
        self.inputRingFD = inputRingFD
        self.outputRingFD = outputRingFD
        self.remoteShim = remoteShim
        self.frameworkLocales = frameworkLocales
        self.resizeFence = resizeFence
    }

    /// Closes every descriptor: the remote shim did not take them.
    func closeDescriptors() {
        for fd in [controlFD, inputRingFD, outputRingFD] where fd >= 0 {
            Darwin.close(fd)
        }
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
