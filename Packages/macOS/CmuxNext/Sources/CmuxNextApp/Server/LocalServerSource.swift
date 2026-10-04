import CmuxNextServer
import CmuxNextSettings
import Foundation

/// A file watch the source re-reads on.
protocol ServerFileWatching: AnyObject {
    func start()
    func stop()
}

extension ConfigFileWatcher: ServerFileWatching {}

/// This Mac's own `server.status` from the bundled CLI (not implemented yet).
@MainActor
final class LocalServerSource: ServerSource {
    nonisolated struct CLIResult: Sendable, Equatable {
        var status: Int32
        var stdout: Data
    }

    typealias RunCLI = @concurrent @Sendable (_ executable: URL, _ arguments: [String]) async -> CLIResult?
    typealias Fix = @MainActor (_ check: HealthCheckID) async -> String?
    typealias MakeWatcher = @MainActor (_ file: URL, _ onChange: @escaping @Sendable () -> Void) -> any ServerFileWatching

    nonisolated static let statusArguments = ["server", "status", "--json"]
    nonisolated static let rolesArguments = ["host", "roles", "--json"]

    init(binary: URL?, hostName: String, watchedFiles: [URL], runCLI: @escaping RunCLI,
         fix: @escaping Fix, makeWatcher: @escaping MakeWatcher) {}

    nonisolated static func watchedFiles(home: URL) -> [URL] { [] }

    func start(_ sink: @escaping @MainActor (ServerSourceEvent) -> Void) {}
    func send(_ intent: ServerIntent) {}
    func stop() {}
    func refresh() {}
}
