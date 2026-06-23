public import AppKit
import Carbon.HIToolbox

/// The keyboard action a PDF file-preview sidebar region resolves a key event
/// to: defer to native AppKit handling, or navigate the page selection by a
/// signed delta.
///
/// The event-to-action mapping lives as static factory members on this owning
/// value type (the type the routing produces): the routing is pure, reads only
/// the event key code / modifier flags and the focus region, and holds no
/// state, matching the file-preview convention of homing pure factory logic on
/// the produced value type rather than a separate static-utility namespace.
public enum FilePreviewPDFKeyboardAction: Equatable, Sendable {
    /// Let AppKit handle the key event normally.
    case native
    /// Navigate the page selection by the given signed delta.
    case navigatePage(Int)

    /// Resolves a key code + modifier flags within a focus region to an action.
    /// Only unmodified arrow / page keys inside the PDF thumbnail region map to
    /// ``navigatePage(_:)``; everything else is ``native``.
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

    /// Resolves an `NSEvent` within a focus region to an action.
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
