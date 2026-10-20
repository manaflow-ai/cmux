import AppKit
import CmuxTerminal
import CmuxTerminalCore

extension GhosttyNSView {
    /// Copies Ghostty's formatted plain selection with terminal wrapping removed.
    @IBAction func copyUnwrapped(_ sender: Any?) {
        guard let surface else { return }
        let snapshot = readSelectionSnapshot(surface: surface)
        let representations = GhosttyApp.terminalPasteboard.captureNextStandardClipboardRepresentations {
            let copy = {
                if self.isKeyboardCopyModeActive {
                    return ghostty_surface_copy_selection_to_clipboard_bounded(
                        surface, UInt(TerminalClipboardRepresentationDecoder.defaultMaximumRichTextBytes)
                    )
                }
                return self.performBindingActionImmediately("copy_to_clipboard:plain")
            }
            if let terminalSurface {
                return terminalSurface.withUserInitiatedClipboardWriteIntent { copy() }
            }
            return copy()
        }
        let text: String
        if let representations {
            guard let plain = representations.first(where: { isPlainTextClipboardRepresentation($0) }) else { return }
            text = plain.string
        } else {
            guard let snapshot else { return }
            text = snapshot.string
        }
        guard !text.isEmpty else { return }
        // Skip soft-wrap probing as well as hard-wrap reflow above the byte budget.
        var unwrapped = text
        if text.utf8.count <= TerminalUnwrappedCopy.maximumUnwrapBytes {
            let columns = Int(ghostty_surface_size(surface).columns)
            let rectangular = !isKeyboardCopyModeActive && copySelectionMayBeRectangular
            let copy = TerminalSoftWrapCopy(hardWrapReflow: false)
            let joined = rectangular ? text : copy.joiningSoftWraps(in: text,
                wrapFlags: ghosttySelectionRowWrapFlags(
                    surface: surface, matchingLineCount: copy.physicalLineCount(in: text)
                )
            )
            let startColumn = snapshot.flatMap {
                $0.topLeft.x >= 0 && columns > 0 ? $0.range.location % columns : nil
            }
            unwrapped = TerminalUnwrappedCopy(
                terminalColumns: columns, rectangular: rectangular, firstLineStartColumn: startColumn
            ).unwrappedText(joined)
        }
        // The capture above diverts Ghostty's write; only this final string is published.
        GhosttyApp.terminalPasteboard.writeString(unwrapped, to: GHOSTTY_CLIPBOARD_STANDARD)
    }
}
