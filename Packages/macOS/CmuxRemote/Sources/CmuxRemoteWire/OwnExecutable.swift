// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// This process's own executable file. The supervisor ships inside the Computer Use helper
/// (`cmux Computer Use.app/Contents/MacOS/cmux-remote`), whose `CFBundleExecutable` is another
/// executable (`cmux-cua`): `Bundle.main.executablePath` names that one, never this. The host
/// starts its workers and its probe from this path.
public enum OwnExecutable {
    /// The path the kernel started this process from, absolute, symlinks resolved; `fallback`
    /// (`argv[0]`) only when the kernel does not say.
    public static func path(fallback: String = CommandLine.arguments.first ?? "") -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return fallback }
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return fallback }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
