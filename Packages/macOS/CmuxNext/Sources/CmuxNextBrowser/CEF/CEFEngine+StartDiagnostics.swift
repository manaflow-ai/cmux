import CmuxNextCompat

/// Chromium's start steps and spare windows as `debug.cef` reports them.
extension CEFEngine {
    /// Records `name` once in the start marks (the first Chromium page's
    /// creation points, `debug.cef` `start_steps`); true, for a `guard`.
    public func notePoint(_ name: String) -> Bool {
        CEFStartSteps.shared.point(name)
        return true
    }

    /// `notePoint(name)`, then `value`.
    public func noted<T>(_ name: String, _ value: T) -> T {
        CEFStartSteps.shared.point(name)
        return value
    }

    /// The timed steps of Chromium's start in this process (`debug.cef`).
    public var startMarks: [CEFStartMark] { CEFStartSteps.shared.marks }

    /// The framework read before CefInitialize (`CEFFrameworkPrefetch`), `debug.cef`'s
    /// `prefetch` fields: bytes, files and milliseconds; nil before one ran. `map_ms` is the time
    /// inside `cef_load_library`, which holds dyld's loader lock (every main-thread dlopen/dladdr
    /// waits on it); `binary_ms` is the read of the binary before it.
    public var frameworkPrefetchFields: [String: Double]? {
        let ms: (Duration) -> Double = { Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1000 }
        return CEFRuntime.shared.prefetch.last.map {
            ["bytes": Double($0.bytes), "files": Double($0.files), "ms": ms($0.duration), "services_ms": ms($0.services),
             "binary_ms": ms($0.binary), "map_ms": ms($0.map)]
        }
    }

    /// The default profile's spare window: `none`, `creating`, `live`, `taken` or `closed` (`debug.cef`).
    public var spareWindowState: String { CEFRuntime.shared.spareWindow.state(of: .browser).rawValue }

    /// The cmux pages profile's spare window, in the same states (`debug.cef` `pages_spare_window`).
    public var pagesSpareWindowState: String { CEFRuntime.shared.spareWindow.state(of: .pages).rawValue }

    /// Windows built in this process for a key a spare serves because no spare of its kind was
    /// ready (`debug.cef` `window_built_on_key_turn`).
    public var windowsBuiltOnKeyTurn: Int { CEFRuntime.shared.spareWindow.windowsBuiltOnKeyTurn }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The renderer client ids of the untaken default-profile spare window's about:blank placeholder (`debug.webui`).
    public var spareWindowRendererClients: [Int32] {
        CEFRuntime.shared.spareWindow.host(of: .browser)?.placeholder?.rendererClientIDs ?? []
    }

    /// The renderer client ids of the untaken pages spare window's about:blank placeholder (`debug.webui`).
    public var pagesSpareWindowRendererClients: [Int32] {
        CEFRuntime.shared.spareWindow.host(of: .pages)?.placeholder?.rendererClientIDs ?? []
    }
    #endif

    /// Main-thread time in Chromium's start steps so far (`MainThreadEngineStart`).
    public var engineStartMainThreadTime: Duration { MainThreadEngineStart.shared.total }
}
