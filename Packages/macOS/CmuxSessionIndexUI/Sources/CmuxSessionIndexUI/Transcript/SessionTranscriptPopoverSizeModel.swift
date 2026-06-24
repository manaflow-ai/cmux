public import CoreGraphics

import Observation

/// The live size of the transcript preview popover, shared between the SwiftUI content
/// and the AppKit popover host so a resize drag updates both.
@MainActor
@Observable
public final class SessionTranscriptPopoverSizeModel {
    /// The current popover content size.
    public var size: CGSize

    /// Creates the size model seeded at `size` (defaults to the standard layout default).
    public init(size: CGSize = SessionTranscriptPreviewLayout.standard.defaultSize) {
        self.size = size
    }
}
