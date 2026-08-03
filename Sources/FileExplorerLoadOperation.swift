import Foundation

struct FileExplorerLoadOperation {
    let identifier: UUID
    let task: Task<Void, Never>
}
