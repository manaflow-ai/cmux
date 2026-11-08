import CoreGraphics
import Observation

@MainActor
@Observable
final class SessionTranscriptPopoverSizeModel {
    var size: CGSize

    init(size: CGSize) {
        self.size = size
    }
}
