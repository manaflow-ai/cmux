import Foundation

struct TextBoxMentionFileIndexRefreshTask {
    let id: UInt64
    let startedAt: Date
    let task: Task<TextBoxMentionCandidateIndex, Never>
}
