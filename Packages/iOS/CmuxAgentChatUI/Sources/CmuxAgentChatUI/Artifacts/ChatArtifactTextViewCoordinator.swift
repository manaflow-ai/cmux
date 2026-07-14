#if canImport(UIKit)
import Foundation

/// Tracks which streamed chunks have been applied to one text-storage instance.
final class ChatArtifactTextViewCoordinator {
    var documentID: String?
    var appliedChunkCount = 0
}
#endif
