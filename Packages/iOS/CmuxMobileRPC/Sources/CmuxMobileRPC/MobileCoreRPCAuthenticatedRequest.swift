internal import Foundation

struct MobileCoreRPCAuthenticatedRequest: Sendable {
    var data: Data
    var usedAttachToken: Bool
}
