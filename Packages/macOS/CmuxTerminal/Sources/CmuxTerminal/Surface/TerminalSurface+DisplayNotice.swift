import Foundation
import GhosttyKit

extension TerminalSurface {
    /// Shows a cmux-authored notice in the terminal display.
    ///
    /// The bytes go through Ghostty's process-output parser, as if the child
    /// had printed them, and never reach the PTY: the shell does not see,
    /// echo, or execute the notice. The text renders dim and the attribute is
    /// reset afterwards. Before the runtime surface exists the notice is
    /// queued and written once, right after the first runtime is sized, so it
    /// appears above the shell's first prompt.
    ///
    /// - Parameter message: The already-localized notice text. Line feeds
    ///   become CRLF; other control characters are dropped so the notice
    ///   cannot drive the terminal.
    @MainActor
    public func writeDisplayNotice(_ message: String) {
        if let liveSurface = liveSurfaceForGhosttyAccess(reason: "displayNotice") {
            flushPendingDisplayNotices(to: liveSurface)
            // A live terminal may have its cursor mid-line; start the notice
            // on a fresh line.
            writeProcessOutputData(
                Self.displayNoticeBytes(message, startsOnNewLine: true),
                to: liveSurface
            )
            return
        }
        let bytes = Self.displayNoticeBytes(message, startsOnNewLine: false)
        guard pendingDisplayNoticeOutput.count + bytes.count <= maxPendingDisplayNoticeBytes else {
            return
        }
        pendingDisplayNoticeOutput.append(bytes)
    }

    /// Admits a deferred startup-restore runtime as a plain shell and shows
    /// `displayNotice` in place of the deferred startup payload.
    ///
    /// Admission semantics match ``admitStartupRestoreRuntime(initialInput:)``:
    /// the runtime is released and scheduled through the normal headless
    /// bootstrap, keeping any restore pacing. The configured startup input
    /// (the deferred agent-resume text) is suppressed, and nothing is typed
    /// into the shell.
    ///
    /// - Parameter displayNotice: The already-localized notice text.
    /// - Returns: `true` when this call admitted the runtime. The notice is
    ///   shown only then.
    @MainActor
    @discardableResult
    public func admitStartupRestoreRuntime(displayNotice: String) -> Bool {
        guard startupRestoreAdmissionPhase == .awaitingAdmission else { return false }
        nextRuntimeInitialInput = nil
        startupRestoreAdmissionCommandOverride = nil
        hasStartupRestoreAdmissionCommandOverride = false
        suppressConfiguredInitialInput = true
        startupRestoreAdmissionPhase = .admitted
        writeDisplayNotice(displayNotice)
        scheduleHeadlessRuntimeStartIfNeeded(reason: "startup-restore-admitted-notice")
        return true
    }

    /// The display-notice bytes queued for the next runtime, decoded as
    /// UTF-8. Empty once flushed. For tests and debug inspection.
    @MainActor
    public func debugPendingDisplayNoticeText() -> String {
        String(decoding: pendingDisplayNoticeOutput, as: UTF8.self)
    }

    /// Writes notices queued before the runtime surface existed. One-shot: a
    /// later runtime recreation does not replay them.
    @MainActor
    func flushPendingDisplayNotices(to surface: ghostty_surface_t) {
        guard !pendingDisplayNoticeOutput.isEmpty else { return }
        let buffered = pendingDisplayNoticeOutput
        pendingDisplayNoticeOutput = Data()
        writeProcessOutputData(buffered, to: surface)
    }

    static func displayNoticeBytes(_ message: String, startsOnNewLine: Bool) -> Data {
        var text = startsOnNewLine ? "\r\n" : ""
        text += "\u{1B}[2m"
        var previousWasCR = false
        for scalar in message.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                text += previousWasCR ? "\n" : "\r\n"
                previousWasCR = false
                continue
            case 0x0D:
                text.unicodeScalars.append(scalar)
                previousWasCR = true
                continue
            case 0x09:
                text.unicodeScalars.append(scalar)
            case 0x00...0x1F, 0x7F...0x9F:
                // ESC, BEL, C1 CSI/OSC introducers and the rest: drop them.
                break
            default:
                text.unicodeScalars.append(scalar)
            }
            previousWasCR = false
        }
        text += "\u{1B}[22m\r\n"
        return Data(text.utf8)
    }
}
