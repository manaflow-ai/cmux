import Foundation

struct WorkspaceCreateWorkingDirectoryProbeKey: Hashable {
    let pathID: Data
    let probeVariant: String?
}
