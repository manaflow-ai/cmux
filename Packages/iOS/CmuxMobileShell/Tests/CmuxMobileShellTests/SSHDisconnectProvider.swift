@testable import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

@MainActor
final class SSHDisconnectProvider: MobileSSHWorkspaceProvider, MobileSSHAttachedTerminal {
    let (attached, attachedContinuation) = AsyncStream<Void>.makeStream()
    let (written, writtenContinuation) = AsyncStream<Void>.makeStream()
    let (detaching, detachingContinuation) = AsyncStream<Void>.makeStream()
    let (resizing, resizingContinuation) = AsyncStream<Void>.makeStream()
    var listCount = 0
    var sizes: [Int] = []
    var geometryReleases = 0
    private var resizeContinuation: CheckedContinuation<Void, Never>?
    private var attachContinuation: CheckedContinuation<any MobileSSHAttachedTerminal, any Error>?
    private var detachContinuation: CheckedContinuation<Void, Never>?

    func listWorkspaces() async throws -> [MobileSSHWorkspace] {
        listCount += 1
        return [MobileSSHWorkspace(id: "work", name: "work", terminals: [MobileSSHTerminal(id: "work/%1", name: "shell")])]
    }

    func createWorkspace() async throws -> MobileSSHWorkspace { throw CancellationError() }
    func closeWorkspace(id: String) async throws {}

    func attach(
        terminalID: String, columns: Int, rows: Int,
        events: @escaping @MainActor (MobileSSHAttachEvent) -> Void
    ) async throws -> any MobileSSHAttachedTerminal {
        try await withCheckedThrowingContinuation { continuation in
            attachContinuation = continuation
            attachedContinuation.yield(())
        }
    }

    func finishAttach() {
        attachContinuation?.resume(returning: self)
        attachContinuation = nil
    }

    func write(_ data: Data) async { writtenContinuation.yield(()) }
    func resize(columns: Int, rows: Int) async {
        sizes.append(columns)
        guard sizes.count == 1 else { return }
        await withCheckedContinuation { continuation in
            resizeContinuation = continuation
            resizingContinuation.yield(())
        }
    }

    func finishResize() {
        resizeContinuation?.resume()
        resizeContinuation = nil
    }

    func releaseGeometry() async { geometryReleases += 1 }
    func detach() async {
        await withCheckedContinuation { continuation in
            detachContinuation = continuation
            detachingContinuation.yield(())
        }
    }

    func finishDetach() {
        detachContinuation?.resume()
        detachContinuation = nil
    }
}
