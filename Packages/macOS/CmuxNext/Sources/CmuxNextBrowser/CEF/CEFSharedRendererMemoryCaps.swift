/// Chrome's memory caps on a shared Chromium renderer, from the app's memory budget
/// (`SubsystemBudget.sharedRendererMemoryCapBytes`, p07-memory task 111).
///
/// ## Chrome reference
///
/// content/browser/renderer_host/render_process_host_impl.cc, Chromium 154:
/// - `HasEnoughMemoryForAnotherMainFrame`: below the process limit a main frame joins a renderer that
///   holds main frames of its site (`kProcessPerSiteUpToMainFrameThreshold`) only while the renderer's
///   private footprint plus 1.5 times its footprint per main frame stays under
///   `kProcessPerSiteMainFrameTotalMemoryLimit` (2 GiB). A renderer with a footprint of 0 (none read yet,
///   or after a crash) takes none.
/// - `IsBelowReuseResourceThresholds`: a subframe joins a same-site renderer only while its footprint is
///   under `g_subframe_process_reuse_memory_threshold` (512 MiB).
///
/// The fork (manaflow-ai/cef `cp/p07-memory-111`, patch `cmux_shared_renderer_memory_cap`) reads both values
/// from ``mainFrameSwitch`` and ``subframeSwitch``. With the main-frame switch it also checks a cmux page that
/// joins a live renderer of its host or group (``CEFSwitches/pageSchemeProcessPerSite``): Chrome sends
/// top-chrome WebUI to a live renderer with no memory check, so a page grown past the cap sends the next one to a
/// new renderer only in cmux. A renderer still launching has room there (its footprint is 0 until it runs); the
/// main-frame cap bounds it. Older forks ignore both switches.
public nonisolated struct CEFSharedRendererMemoryCaps: Equatable, Sendable {
    /// The main-frame limit in bytes (`kProcessPerSiteMainFrameTotalMemoryLimit`).
    public var mainFrameBytes: Int
    /// The subframe limit in bytes (the subframe process reuse threshold).
    public var subframeBytes: Int

    /// Caps of `mainFrameBytes` and `subframeBytes`; a value of 0 or less passes no switch, so Chromium keeps
    /// Chrome's own value.
    public init(mainFrameBytes: Int, subframeBytes: Int) {
        self.mainFrameBytes = mainFrameBytes
        self.subframeBytes = subframeBytes
    }

    /// The fork's main-frame limit switch, in bytes.
    static let mainFrameSwitch = "cmux-shared-renderer-memory-limit"
    /// The fork's subframe limit switch, in bytes.
    static let subframeSwitch = "cmux-shared-renderer-subframe-memory-limit"

    /// `cmux-shared-renderer-memory-limit=<bytes>` and `cmux-shared-renderer-subframe-memory-limit=<bytes>`, each
    /// only for a positive value (the fork reads 0 as no switch).
    var arguments: [String] {
        [(Self.mainFrameSwitch, mainFrameBytes), (Self.subframeSwitch, subframeBytes)]
            .filter { $0.1 > 0 }
            .map { "\($0.0)=\($0.1)" }
    }
}

extension CEFEngine {
    /// The engine, whose Chromium starts with `caps` as its shared-renderer memory caps
    /// (``CEFSharedRendererMemoryCaps``). Read once, when Chromium starts; the process has one Chromium, so the
    /// engine made last gives the caps.
    ///
    /// - Parameter caps: The app's caps (`SubsystemBudget`).
    /// - Returns: This engine.
    @discardableResult
    public func cappingSharedRendererMemory(_ caps: CEFSharedRendererMemoryCaps) -> CEFEngine {
        CEFRuntime.shared.sharedRendererMemoryCaps = caps
        return self
    }
}
