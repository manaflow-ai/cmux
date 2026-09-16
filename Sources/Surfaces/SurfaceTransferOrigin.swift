import Foundation

/// A workspace and its Dock share a workspace ID but are different panel owners.
enum SurfaceTransferOrigin: Equatable, Sendable {
    case workspace(UUID)
    case dock(UUID)
}
