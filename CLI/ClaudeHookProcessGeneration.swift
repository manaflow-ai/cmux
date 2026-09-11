import Foundation

/// Identifies one process generation retained for a delayed Claude lifecycle hook.
struct ClaudeHookProcessGeneration: Codable, Equatable {
    let pid: Int
    let startSeconds: Int64
    let startMicroseconds: Int64
}
