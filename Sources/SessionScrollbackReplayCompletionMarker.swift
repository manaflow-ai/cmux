import Foundation

/// A unique terminal event emitted after replay bytes so completion is ordered with the replay itself.
struct SessionScrollbackReplayCompletionMarker: Equatable, Sendable {
    private static let reportedDirectoryPrefix = "/.cmux-session-scrollback-replay-complete/"
    private let replayID: String

    nonisolated init(fileURL: URL) {
        replayID = fileURL.deletingPathExtension().lastPathComponent
    }

    nonisolated var reportedDirectory: String { Self.reportedDirectoryPrefix + replayID }

    nonisolated func terminalSequence(restoring directory: String) -> String {
        "\u{001B}]7;kitty-shell-cwd://localhost\(reportedDirectory)\u{0007}"
            + "\u{001B}]7;kitty-shell-cwd://localhost\(directory)\u{0007}"
    }

    nonisolated static func isReservedReportedDirectory(_ value: String) -> Bool {
        value.hasPrefix(reportedDirectoryPrefix)
    }
}
