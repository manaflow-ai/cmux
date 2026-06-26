import CoreGraphics
import Observation

/// Mutable size of the session-transcript preview popover.
///
/// Owned by `SessionTranscriptPopoverHost.Coordinator`, which seeds it from
/// `SessionTranscriptPreviewLayout.standard.defaultSize`, clamps it on resize,
/// and mirrors it onto the `NSPopover.contentSize`. `SessionTranscriptPreviewView`
/// reads `size` to drive its frame; observation re-renders the view when the
/// coordinator updates it. `@MainActor` because every reader and writer lives on
/// the main thread (SwiftUI body, AppKit popover coordinator).
@MainActor
@Observable
final class SessionTranscriptPopoverSizeModel {
    var size: CGSize

    init(size: CGSize = SessionTranscriptPreviewLayout.standard.defaultSize) {
        self.size = size
    }
}
