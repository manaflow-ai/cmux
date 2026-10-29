import Foundation

protocol SudoSpoolWatching: Sendable {
    func start(
        paths: SudoBrokerPaths,
        onChange: @Sendable @escaping () -> Void
    ) async throws

    func stop() async
}
