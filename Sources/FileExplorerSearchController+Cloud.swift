import Foundation

@MainActor
extension FileSearchController {
    func startRemoteSearch(vmID: String, query: String, rootPath: String) {
        generation += 1
        let searchGeneration = generation
        emit(status: .searching, isSearching: true)
        let service = cloudFileService
        searchTask = Task { [weak self] in
            do {
                let snapshot = try await service.search(vmID: vmID, query: query, rootPath: rootPath)
                guard !Task.isCancelled else { return }
                self?.finishRemoteSearch(snapshot, generation: searchGeneration)
            } catch is CancellationError {
                return
            } catch {
                self?.finishRemoteSearch(
                    FileSearchSnapshot(query: query, results: [], status: .failed(FileExplorerError.remoteCommandFailed("").localizedDescription), isSearching: false),
                    generation: searchGeneration
                )
            }
        }
        return
    }

    func finishRemoteSearch(_ snapshot: FileSearchSnapshot, generation searchGeneration: Int) {
        guard searchGeneration == generation else { return }
        searchTask = nil
        results = snapshot.results
        emit(status: snapshot.status, isSearching: false)
    }
}
