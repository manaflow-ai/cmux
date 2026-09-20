import Foundation

@MainActor
extension CmuxTuiSurfaceProvider {
    /// Creates an empty workspace when supported so its first shell can carry the Cloud welcome.
    func createRemoteWorkspaceData(
        link: any CloudTuiCommandRunning,
        socketPath: String,
        name: String?,
        expectedRevision: UInt64?
    ) async throws -> Data {
        var arguments = CloudTuiRequests.createWorkspaceArguments(socketPath: socketPath, name: name, empty: true)
        if let expectedRevision { arguments = arguments.adding(["expected_revision": String(expectedRevision)]) }
        do {
            return try await link.run(arguments: arguments)
        } catch {
            let reason = CloudTuiDaemonAnswer(error: error).reason.lowercased()
            guard reason.contains("unsupported") || reason.contains("unknown") || reason.contains("usage.invalid") || reason.contains("initial_content") else { throw error }
            var fallback = CloudTuiRequests.createWorkspaceArguments(socketPath: socketPath, name: name)
            if let expectedRevision { fallback = fallback.adding(["expected_revision": String(expectedRevision)]) }
            return try await link.run(arguments: fallback)
        }
    }
}
