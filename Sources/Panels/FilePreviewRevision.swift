import Observation

@MainActor
@Observable
final class FilePreviewRevision {
    private(set) var value = 0

    func increment() {
        value &+= 1
    }
}
