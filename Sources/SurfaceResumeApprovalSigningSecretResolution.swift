import Foundation

enum SurfaceResumeApprovalSigningSecretResolution: Equatable, Sendable {
    case pending
    case ready(Data?)
}
