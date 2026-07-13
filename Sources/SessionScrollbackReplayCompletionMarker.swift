import Foundation

/// A unique terminal event emitted after replay bytes so completion is ordered with the replay itself.
struct SessionScrollbackReplayCompletionMarker: Equatable, Sendable {
    private static let titlePrefix = "cmux:scrollback-replay-complete:"
    private let replayID: String

    nonisolated init(fileURL: URL) {
        replayID = fileURL.deletingPathExtension().lastPathComponent
    }

    nonisolated var title: String { Self.titlePrefix + replayID }
    nonisolated var terminalSequence: String { "\u{001B}]2;\(title)\u{0007}" }
}
