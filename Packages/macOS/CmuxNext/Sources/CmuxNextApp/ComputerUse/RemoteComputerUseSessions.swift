// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxNextComputerUse
import CmuxNextMacScreen
import Foundation

/// ``ComputerUseSessionControlling`` over cmux Remote's Computer Use worker (the cmux Computer Use
/// engine), through the cmux-tui daemon. The worker does not list its sessions to the app yet, so
/// the focus actions find none; Stop Computer Use ends every session at once
/// (`computer_use.approvals revoke_sessions`). While nothing runs, the reason comes from the phase
/// `computer_use.status` reports (``ComputerUseSetup``).
@MainActor
final class RemoteComputerUseSessions: ComputerUseSessionControlling {
    private let remote: CmuxRemoteService
    private let phase: @MainActor () -> ComputerUseSetup.Phase

    init(remote: CmuxRemoteService, phase: @escaping @MainActor () -> ComputerUseSetup.Phase) {
        self.remote = remote
        self.phase = phase
    }

    func liveSessions() async throws -> [ComputerUseLiveSession] {
        try ready()
        return []
    }

    func stop(_ id: String) async throws {
        try await stopAll()
    }

    func stopAll() async throws {
        try ready()
        do {
            _ = try await remote.call("computer_use.approvals", .object(["action": .string("revoke_sessions")]))
        } catch {
            throw ComputerUseSessionError.failed(ComputerUseSessionStrings.hostRefused(String(describing: error)))
        }
    }

    private func ready() throws {
        let phase = phase()
        guard phase == .ready || phase == .starting else {
            throw ComputerUseSessionError.notRunning(ComputerUseSessionStrings.notRunning(phase))
        }
    }
}
