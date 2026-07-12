import Foundation

struct MobileDiffPatchPayload: Sendable {
    let html: Data
    let patch: Data
}
