public import AppKit
public import CmuxFoundation
import Carbon.HIToolbox

/// Maps raw key events to file-preview PDF navigation actions, scoped to the
/// focused region so the thumbnail strip is the only region that intercepts
/// unmodified arrow and page keys.
public enum FilePreviewPDFKeyboardRouting {
    /// Resolves the action for a key code and modifier set within `region`.
    ///
    /// Returns ``FilePreviewPDFKeyboardAction/native`` for any modifier-bearing
    /// event or any region other than ``FilePreviewPanelFocusIntent/pdfThumbnails``;
    /// otherwise maps up/page-up to a `-1` page delta and down/page-down to `+1`.
    public static func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        region: FilePreviewPanelFocusIntent
    ) -> FilePreviewPDFKeyboardAction {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option, .shift]).isEmpty else {
            return .native
        }

        guard region == .pdfThumbnails else {
            return .native
        }

        switch Int(keyCode) {
        case kVK_UpArrow, kVK_PageUp:
            return .navigatePage(-1)
        case kVK_DownArrow, kVK_PageDown:
            return .navigatePage(1)
        default:
            return .native
        }
    }

    /// Resolves the action for an `NSEvent` within `region`.
    public static func action(
        for event: NSEvent,
        region: FilePreviewPanelFocusIntent
    ) -> FilePreviewPDFKeyboardAction {
        action(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            region: region
        )
    }
}
