import Foundation

/// One streamed patch response and any paths rejected as individually too large.
struct MobileDiffPatchChunk: Sendable {
    let data: Data
    let tooLargePaths: [String]
}
