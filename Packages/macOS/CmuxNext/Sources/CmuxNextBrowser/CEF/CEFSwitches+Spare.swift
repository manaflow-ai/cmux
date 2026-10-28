import Foundation

/// The switches for Chromium's own spare renderer.
nonisolated extension CEFSwitches {
    /// Chrome keeps one spare renderer (live, no site lock, no document) for the profile that
    /// last took a new process (`content/browser/renderer_host/spare_render_process_host_manager_impl.cc`
    /// PrepareForFutureRequests). On desktop it has no destroy timer (StartDestroyTimer gets a
    /// timeout only with Android's kAndroidWarmUpSpareRendererWithTimeout), and
    /// kKillSpareRenderOnMemoryPressure is disabled by default: memory pressure only refuses a
    /// new spare. With this fork switch (manaflow-ai/cef `cp/p13-webui-020`) a profile gets a
    /// spare only after one of its browser tabs starts an http(s) navigation, so the cmux pages
    /// profile, extension background pages and the spare windows should never make one. The
    /// spare keeps Chrome desktop's lifetime. Older forks ignore the switch.
    static let spareRendererAfterFirstTab = "cmux-spare-renderer-after-first-tab"

    /// Chromium's feature for its spare renderer: off, `IsSpareProcessKeptAtAllTimes` is false and
    /// `SpareRenderProcessHostManagerImpl::PrepareForFutureRequests` keeps no spare, as Chrome does
    /// below its low-memory threshold (content/public/common/content_features.cc,
    /// content/browser/renderer_host/spare_render_process_host_manager_impl.cc). It is stock
    /// Chromium's, so every fork reads it.
    static let spareRendererFeature = "SpareRendererForSitePerProcess"
}
