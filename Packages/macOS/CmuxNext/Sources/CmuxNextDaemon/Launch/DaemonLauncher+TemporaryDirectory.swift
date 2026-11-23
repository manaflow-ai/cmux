import Darwin
public import Foundation

extension DaemonLauncher {
    /// The user's per-user temp directory (`confstr(_CS_DARWIN_USER_TEMP_DIR)`),
    /// independent of the process's `TMPDIR`. Falls back to `/tmp`.
    public static func userTemporaryDirectory() -> URL {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        if length > 0 {
            var buffer = [CChar](repeating: 0, count: length)
            if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 {
                let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
            }
        }
        return URL(fileURLWithPath: "/tmp", isDirectory: true)
    }
}
