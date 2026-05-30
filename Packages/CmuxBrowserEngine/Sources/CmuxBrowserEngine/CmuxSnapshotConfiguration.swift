import CoreGraphics
import Foundation
@preconcurrency import WebKit

/// Engine-neutral counterpart to `WKSnapshotConfiguration`. Hosts pass
/// one when calling `CmuxBrowserView.takeSnapshot(configuration:)`.
/// Pass `nil` (or use the no-arg `takeSnapshot`) for engine defaults.
///
/// Today this bridges to `WKSnapshotConfiguration`; Chromium will map
/// onto `RenderWidgetHostView::CopyFromSurface` with the same shape.
public struct CmuxSnapshotConfiguration: Sendable {
    /// Sub-rectangle of the view to snapshot. `.zero` (the default) is
    /// interpreted by WebKit as "full view".
    public var rect: CGRect

    /// Target width in points; height is scaled to preserve aspect.
    /// `nil` matches the view's bounds.
    public var snapshotWidth: CGFloat?

    /// If `true` the engine flushes any pending updates before
    /// capturing. WK defaults to `true`.
    public var afterScreenUpdates: Bool

    public init(
        rect: CGRect = .zero,
        snapshotWidth: CGFloat? = nil,
        afterScreenUpdates: Bool = true
    ) {
        self.rect = rect
        self.snapshotWidth = snapshotWidth
        self.afterScreenUpdates = afterScreenUpdates
    }
}

extension CmuxSnapshotConfiguration {
    /// Builds a `WKSnapshotConfiguration` with the same field values.
    /// Internal — only used by `WebKitBrowserBackend`.
    @MainActor
    func makeWKConfiguration() -> WKSnapshotConfiguration {
        let wk = WKSnapshotConfiguration()
        wk.rect = rect
        if let w = snapshotWidth { wk.snapshotWidth = NSNumber(value: Double(w)) }
        wk.afterScreenUpdates = afterScreenUpdates
        return wk
    }
}
