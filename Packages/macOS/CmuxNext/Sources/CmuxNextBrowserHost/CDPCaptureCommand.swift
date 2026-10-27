import CmuxNextCompat
import Foundation

/// A host CDP command that captures a CEF tab's pixels: it holds the tab's capture vote
/// (``ProviderCaptureVoting``) while it runs, as Chromium's DevTools page handler holds a capturer
/// count for it (content/browser/devtools/protocol/page_handler.cc).
nonisolated enum CDPCaptureCommand: Equatable, Sendable {
    /// `Page.captureScreenshot`: the vote holds until its reply.
    case screenshot
    /// `Page.startScreencast`: the vote holds until `Page.stopScreencast` or the relay's end.
    case startScreencast
    /// `Page.stopScreencast`: ends the screencast's vote.
    case stopScreencast

    private static let methods: [(method: String, command: CDPCaptureCommand)] = [
        ("Page.captureScreenshot", .screenshot),
        ("Page.startScreencast", .startScreencast),
        ("Page.stopScreencast", .stopScreencast),
    ]

    /// The capture command a host command is; nil for every other command. Only a command whose
    /// text names one of the methods is parsed, to read its top-level "method" (a script that
    /// mentions the name is not a capture).
    init?(command message: String) {
        guard let match = Self.methods.first(where: { message.contains($0.method) }),
              let object = (try? JSONSerialization.blockingJSONObject(with: Data(message.utf8))) as? [String: Any],
              object["method"] as? String == match.method else { return nil }
        self = match.command
    }
}
