import Foundation

enum TerminalImageTransferTarget: Equatable, Sendable {
    case local
    case remote(TerminalRemoteUploadTarget)
    /// A managed target never falls back to a local path, including offline mirrors.
    case cloud
}
