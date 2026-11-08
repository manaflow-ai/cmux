import Foundation

enum RemoteTmuxMirrorTeardownReason: Sendable, Equatable {
    case sessionEnded
    case explicitDetach
}
