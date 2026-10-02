import AppKit
import CmuxNextDesign

extension TranscriptGeometry {
    /// The geometry at `width` from the live Metrics and Typography tokens
    /// (density and overrides apply; read inside layout so changes re-lay out).
    static func current(width: CGFloat) -> TranscriptGeometry {
        make(width: width, fontSize: Typography.body.pointSize, captionSize: Typography.caption.pointSize,
             space: (Metrics.space1, Metrics.space2, Metrics.space3, Metrics.space4, Metrics.space5, Metrics.space6))
    }
}
