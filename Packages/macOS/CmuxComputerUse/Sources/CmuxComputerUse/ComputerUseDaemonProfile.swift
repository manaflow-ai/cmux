import Foundation

/// The independently hosted Computer Use protocol surface.
public enum ComputerUseDaemonProfile: CaseIterable, Hashable, Sendable {
    case native
    case codexCompatibility
}
