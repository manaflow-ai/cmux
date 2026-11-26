import Foundation

@MainActor
extension FileSearchController {
    func startRemoteSearch(provider: CloudVMFileExplorerProvider, query: String, rootPath: String) {
        generation += 1
        let searchGeneration = generation
        emit(status: .searching, isSearching: true)
        searchTask = Task { [weak self] in
            do {
                let snapshot = try await provider.search(query: query, rootPath: rootPath)
                guard !Task.isCancelled else { return }
                self?.finishRemoteSearch(snapshot, generation: searchGeneration)
            } catch is CancellationError {
                return
            } catch {
                let message = (error as? FileExplorerError)?.localizedDescription
                    ?? String(localized: "fileExplorer.error.unavailable", defaultValue: "File explorer is not available")
                self?.finishRemoteSearch(
                    FileSearchSnapshot(query: query, results: [], status: .failed(message), isSearching: false),
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
