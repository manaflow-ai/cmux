import AppKit
import os

/// cmux: the bubble column keeps its on-screen width at every Chief chat zoom
/// (https://github.com/manaflow-ai/cmux/issues/28978); `Metrics.maxTextWidth` reads this.
extension Metrics {
    /// The Chief chat's zoom over the zoom whose column every zoom keeps on screen (MessagesLabHomeView's `zoom`
    /// over its `widestColumnZoom`; 1, Messages' own column, outside a zoomed chat). Agent Chat Zoom is one value
    /// for every Chief chat, so this is one process value. The main thread sets it with the zoom, before the width
    /// pass that zoom starts; row layout off the main thread reads it, so a lock guards it.
    static var columnZoom: CGFloat {
        get { columnZoomLock.withLock { $0 } }
        set { columnZoomLock.withLock { $0 = newValue.isFinite && newValue > 0 ? newValue : 1 } }
    }

    private static let columnZoomLock = OSAllocatedUnfairLock<CGFloat>(initialState: 1)
}
