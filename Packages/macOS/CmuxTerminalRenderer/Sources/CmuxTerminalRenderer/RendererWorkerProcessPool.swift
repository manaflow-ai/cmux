public import Foundation
internal import os

/// Launches and owns exactly one renderer helper process per workspace.
public actor RendererWorkerProcessPool {
    public enum Error: Swift.Error {
        case duplicateWorkspace(UUID)
    }

    private struct Worker {
        let process: Process
        let connection: RendererWorkspaceConnection
        let standardInput: Pipe
        let standardOutput: Pipe
        let standardError: Pipe
    }

    private let helperURL: URL
    private var workers: [UUID: Worker] = [:]

    public init(helperURL: URL) {
        self.helperURL = helperURL
    }

    public func start(
        workspaceID: UUID,
        generation _: UInt64
    ) async throws -> RendererWorkspaceConnection {
        guard workers[workspaceID] == nil else {
            throw Error.duplicateWorkspace(workspaceID)
        }

        let input = Pipe()
        let output = Pipe()
        let standardError = Pipe()
        let surfacePortReceiver = try RendererSurfacePortReceiver()
        let process = Process()
        process.executableURL = helperURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = standardError
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_RENDERER_SURFACE_PORT_SERVICE"] = surfacePortReceiver.serviceName
        process.environment = environment

        let errorHandle = standardError.fileHandleForReading
        errorHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                Logger(subsystem: "com.cmuxterm.app", category: "renderer-worker")
                    .error("\(text, privacy: .public)")
            }
        }
        try process.run()

        // The parent owns the opposite ends only.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? standardError.fileHandleForWriting.close()

        let connection = RendererWorkspaceConnection(
            reading: output.fileHandleForReading,
            writing: input.fileHandleForWriting,
            surfacePortReceiver: surfacePortReceiver
        )
        process.terminationHandler = { [weak connection] _ in
            Task { await connection?.cancel() }
        }
        workers[workspaceID] = Worker(
            process: process,
            connection: connection,
            standardInput: input,
            standardOutput: output,
            standardError: standardError
        )
        return connection
    }

    public func stop(workspaceID: UUID) async {
        guard let worker = workers.removeValue(forKey: workspaceID) else { return }
        // Closing stdin is the worker's graceful shutdown signal. Queueing a
        // shutdown frame immediately before closing could discard that frame.
        await worker.connection.cancel()
    }

    public func stopAll() async {
        for workspaceID in Array(workers.keys) {
            await stop(workspaceID: workspaceID)
        }
    }
}
