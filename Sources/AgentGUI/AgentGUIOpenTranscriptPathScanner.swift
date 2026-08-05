import Darwin
import Foundation

struct AgentGUIOpenTranscriptPathScanner {
    static func transcriptPath(pid: Int32, kind: String) -> String? {
        openVnodePaths(pid: pid).first { path in
            switch kind {
            case "codex":
                path.contains("/.codex/") && path.hasSuffix(".jsonl")
            case "claude":
                path.contains("/.claude/") && path.hasSuffix(".jsonl")
            default:
                path.hasSuffix(".jsonl")
            }
        }
    }

    private static func openVnodePaths(pid: Int32) -> [String] {
        let fdInfoSize = MemoryLayout<proc_fdinfo>.stride
        let bufferSize = max(fdInfoSize * 256, 4096)
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let byteCount = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, rawBuffer.baseAddress, Int32(bufferSize))
        }
        guard byteCount > 0 else { return [] }
        let count = Int(byteCount) / fdInfoSize
        return buffer.withUnsafeBytes { rawBuffer -> [String] in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: proc_fdinfo.self) else {
                return []
            }
            var paths: [String] = []
            for index in 0..<count {
                let fd = base[index]
                guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
                if let path = vnodePath(pid: pid, fd: fd.proc_fd) {
                    paths.append(path)
                }
            }
            return paths
        }
    }

    private static func vnodePath(pid: Int32, fd: Int32) -> String? {
        var info = vnode_fdinfowithpath()
        let expectedSize = MemoryLayout<vnode_fdinfowithpath>.stride
        let size = withUnsafeMutableBytes(of: &info) { rawBuffer in
            proc_pidfdinfo(pid_t(pid), fd, PROC_PIDFDVNODEPATHINFO, rawBuffer.baseAddress, Int32(expectedSize))
        }
        guard size == expectedSize else { return nil }
        var pathBuffer = info.pvip.vip_path
        let capacity = MemoryLayout.size(ofValue: pathBuffer)
        return withUnsafePointer(to: &pathBuffer) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                let path = String(cString: chars).trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : path
            }
        }
    }
}
