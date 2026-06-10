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


extension GhosttyNSView: NSTextInputClient {
    /// Deliver committed text using typed-input semantics so shells and editors
    /// keep their normal interactive behaviors (autosuggestions, Return
    /// execution, etc.). Programmatic callers can preserve literal ESC bytes so
    /// automation payloads remain byte-for-byte stable.
    fileprivate func sendTextToSurface(_ chars: String, preserveLiteralEscape: Bool) {
        guard let surface = surface else { return }
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
#endif
#if DEBUG
        cmuxWriteChildExitProbe(
            [
                "probeInsertTextCharsHex": cmuxScalarHex(chars),
                "probeInsertTextSurfaceId": terminalSurface?.id.uuidString ?? "",
            ],
            increments: ["probeInsertTextCount": 1]
        )
#endif

        var bufferedText = ""
        var previousWasCR = false

        func flushBufferedText() {
            guard !bufferedText.isEmpty else { return }
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = GHOSTTY_ACTION_PRESS
            keyEvent.keycode = 0
            keyEvent.mods = GHOSTTY_MODS_NONE
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.unshifted_codepoint = 0
            keyEvent.composing = false
            bufferedText.withCString { ptr in
                keyEvent.text = ptr
                _ = sendGhosttyKey(surface, keyEvent)
            }
            bufferedText.removeAll(keepingCapacity: true)
        }

        func sendControlKey(_ keycode: UInt32) {
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = GHOSTTY_ACTION_PRESS
            keyEvent.keycode = keycode
            keyEvent.mods = GHOSTTY_MODS_NONE
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.unshifted_codepoint = 0
            keyEvent.composing = false
            keyEvent.text = nil
            _ = sendGhosttyKey(surface, keyEvent)
        }

        for scalar in chars.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                if !previousWasCR {
                    flushBufferedText()
                    sendControlKey(0x24) // kVK_Return
                }
                previousWasCR = false
            case 0x0D:
                flushBufferedText()
                sendControlKey(0x24) // kVK_Return
                previousWasCR = true
            case 0x09:
                flushBufferedText()
                sendControlKey(0x30) // kVK_Tab
                previousWasCR = false
            case 0x1B:
                if preserveLiteralEscape {
                    bufferedText.unicodeScalars.append(scalar)
                } else {
                    flushBufferedText()
                    sendControlKey(0x35) // kVK_Escape
                }
                previousWasCR = false
            default:
                bufferedText.unicodeScalars.append(scalar)
                previousWasCR = false
            }
        }
        flushBufferedText()
#if DEBUG
        CmuxTypingTiming.logDuration(
            path: "terminal.sendTextToSurface",
            startedAt: typingTimingStart,
            extra: "textBytes=\(chars.utf8.count)"
        )
#endif
    }

    /// External accessibility/dictation tools should commit plain text, but
    /// some inject a leading escape sequence first. Strip those bytes on the
    /// committed-text path so they can't leak into the PTY as literals.
    static func sanitizeExternalCommittedText(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return text }

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B {
                index = consumeLeadingEscapeSequence(in: bytes, from: index)
                continue
            }

            if byte == 0xC2 {
                let next = index + 1
                if next < bytes.count, bytes[next] == 0x9B {
                    // U+009B (C1 CSI) is encoded as the UTF-8 byte pair C2 9B.
                    index = consumeLeadingCSISequence(in: bytes, from: next + 1)
                    continue
                }
            }

            break
        }

        if index == 0 {
            return text
        }

        guard index < bytes.count else { return "" }
        return String(decoding: bytes[index...], as: UTF8.self)
    }

    private static func consumeLeadingEscapeSequence(
        in bytes: [UInt8],
        from start: Int
    ) -> Int {
        let next = start + 1
        guard next < bytes.count else { return bytes.count }

        switch bytes[next] {
        case 0x5B:
            // CSI: ESC [ ... final
            return consumeLeadingCSISequence(in: bytes, from: next + 1)
        case 0x4F:
            // SS3: ESC O final
            return min(bytes.count, next + 2)
        case 0x50, 0x5D, 0x5E, 0x5F:
            // DCS/OSC/PM/APC: consume until BEL/ST or EOF.
            return consumeLeadingEscapedStringSequence(in: bytes, from: next + 1)
        default:
            // Single-character escape.
            return min(bytes.count, next + 1)
        }
    }

    private static func consumeLeadingCSISequence(
        in bytes: [UInt8],
        from start: Int
    ) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if (0x20...0x3F).contains(byte) {
                index += 1
                continue
            }

            if (0x40...0x7E).contains(byte) {
                return index + 1
            }

            break
        }

        return index
    }

    private static func consumeLeadingEscapedStringSequence(
        in bytes: [UInt8],
        from start: Int
    ) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x07 {
                return index + 1
            }

            if byte == 0x1B {
                let next = index + 1
                if next < bytes.count, bytes[next] == 0x5C {
                    return next + 1
                }
                return index
            }

            if byte < 0x20 || byte == 0x7F {
                return index + 1
            }

            index += 1
        }

        return bytes.count
    }

    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        if markedText.length > 0 {
#if DEBUG
            assert(markedSelectedRange.location != NSNotFound, "markedSelectedRange must be valid")
#endif
            return markedSelectedRange
        }
        return readSelectionSnapshot()?.range ?? NSRange(location: 0, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.setMarkedText",
                startedAt: typingTimingStart,
                extra: "markedLength=\(markedText.length)"
            )
        }
#endif
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            return
        }
        markedSelectedRange = normalizedMarkedSelectionRange(selectedRange, markedLength: markedText.length)

        // If we're not in a keyDown event, sync preedit immediately.
        // This can happen due to external events like changing keyboard layouts
        // while composing.
        if keyTextAccumulator == nil {
            syncPreedit()
            invalidateTextInputCoordinates(selectionChanged: true)
        }
    }

    func unmarkText() {
#if DEBUG
        let hadMarkedText = markedText.length > 0
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.unmarkText",
                startedAt: typingTimingStart,
                extra: "hadMarkedText=\(hadMarkedText ? 1 : 0)"
            )
        }
#endif
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            markedSelectedRange = NSRange(location: NSNotFound, length: 0)
            syncPreedit()
            invalidateTextInputCoordinates(selectionChanged: true)
        }
    }

    /// Sync the preedit state based on the markedText value to libghostty.
    /// This tells Ghostty about IME composition text so it can render the
    /// preedit overlay (e.g. for Korean, Japanese, Chinese input).
    func syncPreedit(clearIfNeeded: Bool = true) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.syncPreedit",
                startedAt: typingTimingStart,
                extra: "markedLength=\(markedText.length) clearIfNeeded=\(clearIfNeeded ? 1 : 0)"
            )
        }
#endif
        guard let surface = surface else { return }

        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    // Subtract 1 for the null terminator
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            // If we had marked text before but don't now, we're no longer
            // in a preedit state so we can clear it.
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        if markedText.length > 0 {
            guard let substringRange = clampedMarkedTextRange(range, markedLength: markedText.length) else { return nil }
            actualRange?.pointee = substringRange
            return markedText.attributedSubstring(from: substringRange)
        }

        guard range.length > 0,
              let snapshot = readSelectionSnapshot() else { return nil }
        actualRange?.pointee = snapshot.range
        return NSAttributedString(string: snapshot.string)
    }

    func characterIndex(for point: NSPoint) -> Int {
        return selectedRange().location
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window = self.window else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        // Use Ghostty's IME point API for accurate cursor position if available.
        var x: Double = 0
        var y: Double = 0
        var w: Double = cellSize.width
        var h: Double = cellSize.height
#if DEBUG
        if range.length > 0,
           range != selectedRange(),
           let snapshot = readSelectionSnapshot() {
            x = snapshot.topLeft.x - 2
            y = snapshot.topLeft.y + 2
        } else if let override = imePointOverrideForTesting {
            x = override.x
            y = override.y
            w = override.width
            h = override.height
        } else if let surface = surface {
            ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        }
#else
        if range.length > 0,
           range != selectedRange(),
           let snapshot = readSelectionSnapshot() {
            x = snapshot.topLeft.x - 2
            y = snapshot.topLeft.y + 2
        } else if let surface = surface {
            ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        }
#endif

        if range.length == 0, w > 0 {
            // Dictation expects a caret rect for insertion points rather than a box.
            w = 0
        }

        // Ghostty coordinates are top-left origin; AppKit expects bottom-left.
        let viewRect = NSRect(
            x: x,
            y: frame.size.height - y,
            width: w,
            height: max(h, cellSize.height)
        )
        let winRect = convert(viewRect, to: nil)
        return window.convertToScreen(winRect)
    }

    func attributedString() -> NSAttributedString {
        if markedText.length > 0 {
            return NSAttributedString(attributedString: markedText)
        }
        if let snapshot = readSelectionSnapshot(), !snapshot.string.isEmpty {
            return NSAttributedString(string: snapshot.string)
        }
        return NSAttributedString(string: "")
    }

    func windowLevel() -> Int {
        Int(window?.level.rawValue ?? NSWindow.Level.normal.rawValue)
    }

    @available(macOS 14.0, *)
    var unionRectInVisibleSelectedRange: NSRect {
        firstRect(forCharacterRange: selectedRange(), actualRange: nil)
    }

    @available(macOS 14.0, *)
    var documentVisibleRect: NSRect {
        visibleDocumentRectInScreenCoordinates()
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.insertText",
                startedAt: typingTimingStart,
                event: NSApp.currentEvent,
                extra: "replacementLocation=\(replacementRange.location) replacementLength=\(replacementRange.length)"
            )
        }
#endif
        // Get the string value
        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        if keyTextAccumulator != nil,
           shouldBufferBopomofoInsertedPreedit(chars) {
            insertBopomofoPreeditText(chars, replacementRange: replacementRange)
            return
        }

        // Clear marked text since we're inserting
        unmarkText()

        // Some IME/input-method paths call insertText with an empty payload to
        // flush state. There is no terminal text to send in that case.
        guard !chars.isEmpty else { return }

        if shouldSuppressDeferredNumpadIMECommit(chars) {
            return
        }

#if DEBUG
        if NSApp.currentEvent == nil {
            cmuxDebugLog("ime.insertText.noEvent len=\(chars.count)")
        }
#endif

        // If we have an accumulator, we're in a keyDown event - accumulate the text
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        let isExternalCommittedText = externalCommittedTextDepth > 0
        let sanitizedChars = if isExternalCommittedText {
            // Only sanitize explicit external committed-text paths used by
            // AX/dictation integrations. Programmatic NSTextInputClient callers
            // may intentionally start with ESC/CSI bytes.
            Self.sanitizeExternalCommittedText(chars)
        } else {
            chars
        }

#if DEBUG
        if sanitizedChars != chars {
            cmuxDebugLog(
                "ime.insertText.sanitized originalBytes=\(chars.utf8.count) " +
                "sanitizedBytes=\(sanitizedChars.utf8.count)"
            )
        }
#endif

        guard !sanitizedChars.isEmpty else { return }

        // Otherwise send directly to the terminal
        recordDirectAgentHibernationTerminalInput()
        sendTextToSurface(
            sanitizedChars,
            preserveLiteralEscape: !isExternalCommittedText
        )
    }

    private func insertBopomofoPreeditText(_ chars: String, replacementRange: NSRange) {
        let effectiveRange = effectiveBopomofoPreeditReplacementRange(replacementRange)
        if let range = Range(effectiveRange, in: markedText.string) {
            let insertionLocation = effectiveRange.location + (chars as NSString).length
            let next = markedText.string.replacingCharacters(in: range, with: chars)
            markedText = NSMutableAttributedString(string: next)
            markedSelectedRange = normalizedMarkedSelectionRange(
                NSRange(location: insertionLocation, length: 0),
                markedLength: markedText.length
            )
            return
        }

        markedText.append(NSAttributedString(string: chars))
        markedSelectedRange = normalizedMarkedSelectionRange(
            NSRange(location: markedText.length, length: 0),
            markedLength: markedText.length
        )
    }

    private func effectiveBopomofoPreeditReplacementRange(_ replacementRange: NSRange) -> NSRange {
        guard replacementRange.location == NSNotFound else { return replacementRange }
        guard markedText.length > 0 else { return NSRange(location: 0, length: 0) }
        return normalizedMarkedSelectionRange(markedSelectedRange, markedLength: markedText.length)
    }
}
