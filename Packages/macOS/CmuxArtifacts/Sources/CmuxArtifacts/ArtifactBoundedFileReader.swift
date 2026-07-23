import Darwin
import Foundation

/// Reads one regular artifact through a no-follow descriptor with a hard byte cap.
struct ArtifactBoundedFileReader {
    func pathEntryExists(url: URL) throws -> Bool {
        var status = stat()
        if lstat(url.path, &status) == 0 { return true }
        if errno == ENOENT { return false }
        throw CocoaError(.fileReadUnknown)
    }

    func data(url: URL, allowedRoot: URL, maximumBytes: Int64) throws -> Data? {
        try Task.checkCancellation()
        guard maximumBytes >= 0, maximumBytes < Int.max else { return nil }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0,
              status.st_size <= maximumBytes else {
            return nil
        }

        var descriptorInfo = vnode_fdinfowithpath()
        let pathResult = proc_pidfdinfo(
            Darwin.getpid(),
            descriptor,
            PROC_PIDFDVNODEPATHINFO,
            &descriptorInfo,
            Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        )
        guard pathResult > 0 else { return nil }
        let descriptorPath = withUnsafeBytes(of: &descriptorInfo.pvip.vip_path) { rawBuffer -> String in
            guard let baseAddress = rawBuffer.baseAddress else { return "" }
            return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
        }
        let descriptorURL = URL(fileURLWithPath: descriptorPath, isDirectory: false)
        guard ArtifactPathResolver().relativePath(descriptorURL, root: allowedRoot) != nil else {
            return nil
        }

        let limit = Int(maximumBytes)
        var data = Data()
        data.reserveCapacity(min(Int(status.st_size), limit))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, limit + 1))
        while data.count <= limit {
            try Task.checkCancellation()
            let requested = min(buffer.count, limit + 1 - data.count)
            guard requested > 0 else { break }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data.count <= limit ? data : nil
    }
}
