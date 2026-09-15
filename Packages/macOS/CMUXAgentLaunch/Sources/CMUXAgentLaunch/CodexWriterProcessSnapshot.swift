import Foundation

struct CodexWriterFileIdentity: Hashable, Sendable {
    let device: UInt32
    let inode: UInt64

    init?(lock: CodexWriterLockInspection) {
        guard let device = lock.device, let inode = lock.inode else { return nil }
        self.device = UInt32(bitPattern: device)
        self.inode = inode
    }

    init(device: UInt32, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

struct CodexWriterProcessSnapshot: Sendable {
    var holders: [CodexWriterFileIdentity: [CodexWriterProcessEvidence]] = [:]
    var watchedPorts: Set<Int> = []
    var isComplete = true
}

protocol CodexWriterProcessInspecting: Sendable {
    func snapshot(locks: [CodexWriterLockInspection]) -> CodexWriterProcessSnapshot
    func terminate(_ holder: CodexWriterProcessEvidence) -> Bool
}
