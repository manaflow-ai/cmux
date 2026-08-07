import Foundation

/// Derived transcript-batch classifications shared by Mac capture and chat consumers.
public extension Collection where Element == ChatMessage {
    /// Whether the batch carries committed agent prose that settles live preview.
    var containsAgentProse: Bool {
        contains { message in
            guard message.role == .agent else { return false }
            if case .prose = message.kind { return true }
            return false
        }
    }
}
