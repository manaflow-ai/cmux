import CmuxRemoteConnections
import Foundation

/// Main-actor state that bridges an SSH host-key prompt into SwiftUI.
@MainActor
final class MobileRemoteHostApprovalState {
    var challenge: MobileRemoteSSHHostKeyChallenge?
    private var continuation: CheckedContinuation<Bool, Never>?

    func request(_ challenge: MobileRemoteSSHHostKeyChallenge) async -> Bool {
        await withCheckedContinuation { continuation in
            self.challenge = challenge
            self.continuation = continuation
        }
    }

    func resolve(_ approved: Bool) {
        challenge = nil
        continuation?.resume(returning: approved)
        continuation = nil
    }

    func cancel() {
        resolve(false)
    }
}
