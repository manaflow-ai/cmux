import Foundation

/// A paste failure worth a brief on-screen notice in addition to the beep.
///
/// Only two failures qualify: an image over the clipboard image cap (which
/// used to fail silently) and a paste worker that ran past its deadline (which
/// used to be only a beep). Every other failure keeps its existing behavior.
enum TerminalPasteFailureNotice: Equatable, Sendable {
    case imageTooLarge
    case timedOut

    /// The notice for a terminal paste outcome, or nil when there is nothing
    /// to show. Pure, so a test can check the mapping without an app host.
    static func notice(
        for outcome: TerminalImageTransferPreparationOutcome
    ) -> TerminalPasteFailureNotice? {
        if outcome.failure == .deadlineExceeded { return .timedOut }
        if outcome.content == .rejectOversizedImage { return .imageTooLarge }
        return nil
    }

    var message: String {
        switch self {
        case .imageTooLarge:
            // Matches TerminalPasteboardService.maxClipboardImageSize (10 MiB);
            // CmuxTerminal's tests pin that constant to this text.
            return String(
                localized: "terminal.paste.notice.imageTooLarge",
                defaultValue: "Image is larger than 10 MB"
            )
        case .timedOut:
            return String(
                localized: "terminal.paste.notice.timedOut",
                defaultValue: "Paste timed out"
            )
        }
    }
}
