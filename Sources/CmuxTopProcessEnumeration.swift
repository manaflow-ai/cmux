import CmuxFoundation
import Darwin
import Foundation

private nonisolated let cmuxTopPIDPathBufferSize = 4096

extension CmuxTopProcessSnapshot {
    static func deviceIdentifier(forTTYName ttyName: String) -> Int64? {
        let trimmed = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "not a tty" else {
            return nil
        }

        let path: String
        if trimmed.hasPrefix("/dev/") {
            path = trimmed
        } else {
            path = "/dev/\(trimmed)"
        }

        var statInfo = stat()
        guard stat(path, &statInfo) == 0 else {
            return nil
        }
        return Int64(statInfo.st_rdev)
    }

    static func taskInfo(for pid: Int) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let expectedSize = MemoryLayout<proc_taskinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTASKINFO, 0, &info, Int32(expectedSize))
        return size == expectedSize ? info : nil
    }

    static func resourceUsage(for pid: Int) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutableBytes(of: &info) { rawBuffer -> Int32 in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            // proc_pid_rusage imports as rusage_info_t *; callers pass the concrete
            // rusage struct address cast to that opaque buffer type.
            let buffer = baseAddress.assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(
                pid_t(pid),
                RUSAGE_INFO_V4,
                buffer
            )
        }
        return result == 0 ? info : nil
    }

    static func processName(pid: Int, fallback: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN + 1))
        let length = proc_name(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return fallback }
        let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : name
    }

    static func processPath(pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: cmuxTopPIDPathBufferSize)
        let length = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    static func fixedString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { rawBuffer in
            let endIndex = rawBuffer.firstIndex(of: 0) ?? rawBuffer.endIndex
            return String(decoding: rawBuffer[..<endIndex], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func int64Clamped(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}
