import Foundation

/// Keeps the plain-text reader's process and pasteboard connection warm.
/// A failed or cancelled reader is reaped before its replacement is admitted.
actor TerminalPlainTextPasteWorkerPool {
    private let executableURL: URL
    private var reader: Task<TerminalPlainTextPasteWorkerConnection, Error>
    private var generation = UUID()

    init(executableURL: URL) {
        self.executableURL = executableURL
        reader = Self.startReader(executableURL: executableURL)
    }

    func request(_ data: Data) async throws -> (status: Int32, payload: Data) {
        try Task.checkCancellation()
        let currentGeneration = generation
        do {
            let connection = try await reader.value
            return try await connection.request(data)
        } catch {
            if generation == currentGeneration {
                generation = UUID()
                reader = Self.startReader(executableURL: executableURL)
            }
            throw error
        }
    }

    private static func startReader(
        executableURL: URL
    ) -> Task<TerminalPlainTextPasteWorkerConnection, Error> {
        Task {
            let connection = TerminalPlainTextPasteWorkerConnection(executableURL: executableURL)
            try await connection.start()
            return connection
        }
    }
}
