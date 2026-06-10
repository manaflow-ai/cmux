import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CmuxFileWatch
import CmuxGit
import CmuxProcess
import CoreVideo
import Combine
import CoreServices
import Darwin
import OSLog


// MARK: - Workspace Git Metadata Probe Support
protocol WorkspaceGitMetadataReading: Sendable {
    func workspaceMetadata(for directory: String) async -> GitWorkspaceMetadata
}

extension GitMetadataService: WorkspaceGitMetadataReading {}

private struct WorkspaceGitMetadataProbeWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
}

actor WorkspaceGitMetadataProbeLimiter {
    static let shared = WorkspaceGitMetadataProbeLimiter(limit: 2)

    private let limit: Int
    private var activeCount = 0
    private var waiters: [WorkspaceGitMetadataProbeWaiter] = []
    private var cancelledWaiterIds: Set<UUID> = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async -> Bool {
        let id = UUID()
        guard !Task.isCancelled else { return false }
        if activeCount < limit {
            activeCount += 1
            return true
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledWaiterIds.remove(id) != nil {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(WorkspaceGitMetadataProbeWaiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: id)
            }
        }
    }

    func release() {
        guard activeCount > 0 else { return }
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            if cancelledWaiterIds.remove(waiter.id) != nil {
                waiter.continuation.resume(returning: false)
                continue
            }
            waiter.continuation.resume(returning: true)
            return
        }
        activeCount -= 1
    }

    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: false)
        } else {
            cancelledWaiterIds.insert(id)
        }
    }
}

