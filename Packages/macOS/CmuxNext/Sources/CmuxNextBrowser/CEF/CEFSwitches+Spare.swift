import Foundation

/// The switches for Chromium's own spare renderer.
nonisolated extension CEFSwitches {
    /// Chromium's feature for its spare renderer: off, `IsSpareProcessKeptAtAllTimes` is false and
    /// `SpareRenderProcessHostManagerImpl::PrepareForFutureRequests` keeps no spare, as Chrome does
    /// below its low-memory threshold (content/public/common/content_features.cc,
    /// content/browser/renderer_host/spare_render_process_host_manager_impl.cc). It is stock
    /// Chromium's, so every fork reads it.
    static let spareRendererFeature = "SpareRendererForSitePerProcess"
}
