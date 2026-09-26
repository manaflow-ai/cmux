import AppKit
import CmuxFilePreviewCore

/// Bridges immutable Vim navigation state to one native text preview.
@MainActor
final class FilePreviewVimController {
    private weak var textView: NSTextView?
    private var navigation: ReadOnlyVimNavigation
    private var appliedSelection: NSRange?
    private let prompt = NSTextField(labelWithString: "")

    init(textView: NSTextView) {
        self.textView = textView
        navigation = ReadOnlyVimNavigation(text: textView.string)
        navigation.move(to: textView.selectedRange().location)
        prompt.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        prompt.drawsBackground = true
        prompt.backgroundColor = .textBackgroundColor
        prompt.textColor = .textColor
        prompt.isHidden = true
        prompt.identifier = NSUserInterfaceItemIdentifier("FilePreviewVimSearchPrompt")
    }

    func resetDocument() {
        guard let textView else { return }
        navigation = ReadOnlyVimNavigation(text: textView.string)
        navigation.move(to: textView.selectedRange().location)
        appliedSelection = nil
        cancelPendingInput()
    }

    func cancelPendingInput() {
        navigation.cancelPendingInput()
        prompt.removeFromSuperview()
    }

    func handle(_ event: NSEvent) -> Bool {
        guard let textView else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Preserve configured Command shortcuts, native copy/find, and Option text handling.
        // isEditable/shouldChangeText still prevent those paths from mutating the buffer.
        guard !flags.contains(.command), !flags.contains(.option) else { return false }
        if textView.selectedRange() != appliedSelection {
            navigation.adoptNativeCursor(textView.selectedRange().location)
        }
        let key: String
        switch event.keyCode {
        case 53: key = "escape"
        case 36, 76: key = "enter"
        case 51, 117: key = "backspace"
        case 123: key = "h"
        case 124: key = "l"
        case 125: key = "j"
        case 126: key = "k"
        default:
            guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return true }
            key = flags.contains(.control) ? "ctrl+" + characters.lowercased() : characters
        }
        navigation.handle(key)
        if let action = navigation.viewportAction { apply(action, to: textView) }
        if let value = navigation.yankedText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
        let selection = navigation.selection
        textView.setSelectedRange(selection)
        appliedSelection = selection
        if navigation.viewportAction == nil { textView.scrollRangeToVisible(selection) }
        updatePrompt(in: textView)
        return true
    }

    private func updatePrompt(in textView: NSTextView) {
        guard let value = navigation.searchPrompt, let scrollView = textView.enclosingScrollView else {
            prompt.removeFromSuperview()
            return
        }
        prompt.stringValue = value
        prompt.isHidden = false
        prompt.frame = NSRect(x: 4, y: 4, width: max(0, scrollView.bounds.width - 8), height: 24)
        prompt.autoresizingMask = [.width, .maxYMargin]
        if prompt.superview !== scrollView { scrollView.addSubview(prompt) }
    }

    private func apply(_ action: ReadOnlyVimViewportAction, to textView: NSTextView) {
        guard !textView.string.isEmpty,
              let scrollView = textView.enclosingScrollView,
              let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        let clip = scrollView.contentView
        let inset = textView.textContainerOrigin
        let position = min(navigation.cursor, max(0, (textView.string as NSString).length - 1))
        let glyph = layout.glyphIndexForCharacter(at: position)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        switch action {
        case .align(let fraction):
            scroll(to: line.minY + inset.y - (clip.bounds.height - line.height) * fraction, in: scrollView)
        case .page(let pages):
            let delta = clip.bounds.height * pages
            let glyphPosition = layout.location(forGlyphAt: glyph)
            let point = NSPoint(x: line.minX + glyphPosition.x, y: max(0, line.midY + delta))
            let target = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            navigation.move(to: target)
            scroll(to: clip.bounds.minY + delta, in: scrollView)
        case .visibleLine(let fraction):
            let y = clip.bounds.minY + max(0, clip.bounds.height - line.height) * fraction - inset.y
            let target = layout.characterIndex(for: NSPoint(x: 0, y: max(0, y)), in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            navigation.move(to: target)
        }
    }

    private func scroll(to y: CGFloat, in scroll: NSScrollView) {
        let clip = scroll.contentView
        let rect = NSRect(x: clip.bounds.minX, y: y, width: clip.bounds.width, height: clip.bounds.height)
        clip.scroll(to: clip.constrainBoundsRect(rect).origin)
        scroll.reflectScrolledClipView(clip)
    }
}
