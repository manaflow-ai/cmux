public import Foundation

// `shell-runs-v1` (cmux-tui `crates/cmux-tui-core/src/shell_runs.rs`, `server/shell_wire.rs`):
// shell mode's commands of a chat on another machine run there, on its daemon. A refusal is an
// answer (`refused`), so its code reaches the app also over a remote link. The requests are
// generated (`*.generated.swift`); the schema types their replies as JSON, so they are read here.

extension ShellRunRequest {
    /// A new run id in the daemon's form: `run_` and 32 lowercase hex digits (128 random bits).
    public static func newRunID() -> String {
        var generator = SystemRandomNumberGenerator()
        return "run_" + (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    public nonisolated struct Response: Decodable, Sendable, Equatable {
        public let run: String?
        public let refused: String?
    }
}

extension ShellReadRequest {
    /// The daemon's long poll plus the link's own time.
    public static let timeout: Duration = .seconds(20)

    public nonisolated struct Response: Decodable, Sendable, Equatable {
        public let output: String?
        public let next: Int?
        public let truncated: Bool?
        public let exit: Exit?
        public let refused: String?

        public nonisolated struct Exit: Decodable, Sendable, Equatable {
            public let code: Int32?
            public let signal: Int32?
        }
    }
}

extension ShellStopRequest {
    public nonisolated struct Response: Decodable, Sendable, Equatable {
        public let refused: String?
    }
}
