import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers


// MARK: - Accessibility
extension GhosttyNSView {
    /// Expose the terminal surface as an editable accessibility element.
    /// Voice input tools frequently target AX text areas for text insertion.
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override func accessibilityHelp() -> String? {
        "Terminal content area"
    }

    override func accessibilityValue() -> Any? {
        // We don't keep a full terminal text snapshot in this layer.
        // Expose selected text when available; otherwise provide an empty value
        // so AX clients still treat this as an editable text area.
        accessibilitySelectedText() ?? ""
    }

    override func setAccessibilityValue(_ value: Any?) {
        let content: String
        switch value {
        case let v as NSAttributedString:
            content = v.string
        case let v as String:
            content = v
        default:
            return
        }

        guard !content.isEmpty else { return }

#if DEBUG
        cmuxDebugLog("ime.ax.setValue len=\(content.count)")
#endif

        let inject = {
            self.withExternalCommittedText {
                self.insertText(content, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        if Thread.isMainThread {
            inject()
        } else {
            DispatchQueue.main.async(execute: inject)
        }
    }

    func withExternalCommittedText<T>(_ body: () -> T) -> T {
        externalCommittedTextDepth += 1
        defer { externalCommittedTextDepth -= 1 }
        return body()
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        selectedRange()
    }

    override func accessibilitySelectedText() -> String? {
        guard let snapshot = readSelectionSnapshot() else { return nil }
        return snapshot.string.isEmpty ? nil : snapshot.string
    }

    func readSelectionSnapshot() -> SelectionSnapshot? {
        guard let surface else { return nil }

        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        let selected: String
        if let ptr = text.text, text.text_len > 0 {
            let selectedData = Data(bytes: ptr, count: Int(text.text_len))
            selected = String(decoding: selectedData, as: UTF8.self)
        } else {
            selected = ""
        }

        return SelectionSnapshot(
            range: NSRange(location: Int(text.offset_start), length: Int(text.offset_len)),
            string: selected,
            topLeft: CGPoint(x: text.tl_px_x, y: text.tl_px_y)
        )
    }

    func visibleDocumentRectInScreenCoordinates() -> NSRect {
        let localRect = visibleRect
        let windowRect = convert(localRect, to: nil)
        guard let window else { return windowRect }
        return window.convertToScreen(windowRect)
    }

    func invalidateTextInputCoordinates(selectionChanged: Bool = false) {
        guard let inputContext else { return }
        inputContext.invalidateCharacterCoordinates()
        guard selectionChanged else { return }

        // `textInputClientDidUpdateSelection` is absent from the Xcode 16.2 AppKit SDK
        // used by the macOS 14 compatibility lane, so call it dynamically when present.
        let updateSelectionSelector = NSSelectorFromString("textInputClientDidUpdateSelection")
        guard inputContext.responds(to: updateSelectionSelector) else { return }
        _ = inputContext.perform(updateSelectionSelector)
    }

    struct SelectionSnapshot {
        let range: NSRange
        let string: String
        let topLeft: CGPoint
    }

}
