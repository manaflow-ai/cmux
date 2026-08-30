import Foundation

/// The independently hosted Computer Use protocol surface.
enum ComputerUseDaemonProfile: CaseIterable, Hashable, Sendable {
    case native
    case codexCompatibility
}
