import Foundation

/// `process-info` result (protocol 6+; `foreground_cwd` additive in 12).
struct CmuxTUIProcessInfoWire: Decodable, Sendable {
    var pid: UInt32?
    var command: String?
    var cwd: String?
    var foreground_cwd: String?
}

extension CmuxTUIControl {
    /// The shell's current directory for `surface`: the live working
    /// directory of the PTY's foreground process group when the server can
    /// read it (it follows `cd`), otherwise the recorded spawn or
    /// shell-reported directory. `nil` when neither is known.
    public func workingDirectory(surface: Int) async throws -> String? {
        let info = try await request("process-info", ["surface": .int(surface)], as: CmuxTUIProcessInfoWire.self)
        return [info.foreground_cwd, info.cwd]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }
}
