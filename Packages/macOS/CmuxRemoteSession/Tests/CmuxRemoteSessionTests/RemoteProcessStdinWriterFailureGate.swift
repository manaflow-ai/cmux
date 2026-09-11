import Foundation

enum RemoteProcessStdinWriterFailureGate: Equatable, Sendable {
    case launched
    case exited
}
