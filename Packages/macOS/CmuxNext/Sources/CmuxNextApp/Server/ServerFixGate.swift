import Foundation

/// One helper conversation at a time on this Mac (not implemented yet).
@MainActor
final class ServerFixGate {
    static let shared = ServerFixGate()

    func acquire() async {}
    func release() {}
}
