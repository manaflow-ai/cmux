import Darwin
import Foundation

/// Uses the kernel's cached mount table to reject remote Git config reads.
struct SystemGitFilesystemLocalityReader: GitFilesystemLocalityReading {
    private let mountLocalityByPath: [String: Bool]

    init() {
        var mountBuffer: UnsafeMutablePointer<statfs>?
        let mountCount = getmntinfo_r_np(&mountBuffer, MNT_NOWAIT)
        defer {
            if let mountBuffer {
                free(UnsafeMutableRawPointer(mountBuffer))
            }
        }
        guard mountCount > 0, let mountBuffer else {
            mountLocalityByPath = [:]
            return
        }

        var localityByPath: [String: Bool] = [:]
        localityByPath.reserveCapacity(Int(mountCount))
        for index in 0..<Int(mountCount) {
            let fileSystem = mountBuffer[index]
            let path = withUnsafePointer(to: fileSystem.f_mntonname) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
            localityByPath[
                URL(fileURLWithPath: path).standardizedFileURL.path
            ] = (fileSystem.f_flags & UInt32(MNT_LOCAL)) != 0
        }
        mountLocalityByPath = localityByPath
    }

    func isLocal(path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        var longestMatchLength = -1
        var longestMatchIsLocal = false
        for (mountPath, isLocal) in mountLocalityByPath {
            let matches = normalized == mountPath
                || normalized.hasPrefix(mountPath.hasSuffix("/") ? mountPath : mountPath + "/")
            guard matches, mountPath.count > longestMatchLength else { continue }
            longestMatchLength = mountPath.count
            longestMatchIsLocal = isLocal
        }
        return longestMatchLength >= 0 && longestMatchIsLocal
    }
}
