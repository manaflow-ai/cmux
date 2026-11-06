// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// `cmux-cu-service mcp`: the MCP server an agent spawns. It holds no grants
/// and runs no Computer Use code; it pumps bytes between stdio and the
/// engine's socket, starting the engine app in the background when nothing
/// listens yet. macOS then attributes Accessibility and Screen Recording to
/// the engine app, never to the agent's process tree.
public struct SocketBridge: Sendable {
    public let socket: EngineSocket
    public let appPath: String?

    public init(socket: EngineSocket, appPath: String?) {
        self.socket = socket
        self.appPath = appPath
    }

    public enum BridgeError: Error, CustomStringConvertible {
        case notRunning(String)
        public var description: String {
            switch self {
            case .notRunning(let path): "the Computer Use engine is not running at \(path)"
            }
        }
    }

    /// Connects, launching the app once if needed (bounded wait: 5 s).
    public func connectOrLaunch() throws -> Int32 {
        if let fd = socket.connect() { return fd }
        if let appPath {
            // `open -g -j`: launched hidden in the background, never fronted.
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "-j", "-a", appPath]
            try? open.run()
            open.waitUntilExit()
            for _ in 0..<250 {
                usleep(20_000)
                if let fd = socket.connect() { return fd }
            }
        }
        throw BridgeError.notRunning(socket.path)
    }

    /// Pumps stdio both ways until either side closes.
    public func run() throws -> Never {
        let fd = try connectOrLaunch()
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let upstream = Thread {
            Self.pump(STDIN_FILENO, fd)
            Darwin.shutdown(fd, SHUT_WR)
        }
        upstream.start()
        Self.pump(fd, STDOUT_FILENO)
        exit(0)
    }

    /// Copies `from` to `to` until EOF or an error.
    static func pump(_ from: Int32, _ to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(from, &buffer, buffer.count)
            if count <= 0 { return }
            var written = 0
            while written < count {
                let n = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return write(to, base + written, count - written)
                }
                if n <= 0 { return }
                written += n
            }
        }
    }
}
