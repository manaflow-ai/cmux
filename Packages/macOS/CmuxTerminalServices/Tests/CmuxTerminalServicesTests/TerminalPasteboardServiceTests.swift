import AppKit
import CmuxTerminalCore
import Foundation
import GhosttyKit
import Testing
import UniformTypeIdentifiers

@testable import CmuxTerminalServices

/// A scratch pasteboard with a unique name, released when the test ends.
private final class ScratchPasteboard {
    let pasteboard: NSPasteboard

    init() {
        pasteboard = NSPasteboard(name: .init("cmux-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    deinit {
        pasteboard.clearContents()
        pasteboard.releaseGlobally()
    }
}

private func makeScratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmux-pasteboard-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func tinyPNGData() throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

@Suite("Terminal shell escaping")
struct TerminalShellEscapingTests {
    @Test func escapesShellSpecialCharacters() {
        #expect("/tmp/a b(c).png".terminalShellEscaped == "/tmp/a\\ b\\(c\\).png")
        #expect("plain.png".terminalShellEscaped == "plain.png")
        #expect("a$b;c|d".terminalShellEscaped == "a\\$b\\;c\\|d")
    }

    @Test func singleQuotesValuesContainingNewlines() {
        #expect("a\nb".terminalShellEscaped == "'a\nb'")
        #expect("it's\r".terminalShellEscaped == "'it'\\''s\r'")
    }
}

@Suite("Pasteboard text contents")
struct PasteboardTextContentsTests {
    @Test func prefersUTF8PlainTextOverLossyTraditionalMacText() {
        let scratch = ScratchPasteboard()
        let service = TerminalPasteboardService()
        let lossyType = NSPasteboard.PasteboardType("com.apple.traditional-mac-plain-text")
        scratch.pasteboard.declareTypes(
            [lossyType, .init("public.utf8-plain-text"), .string],
            owner: nil
        )
        scratch.pasteboard.setString("???", forType: lossyType)
        scratch.pasteboard.setString("日本語", forType: .init("public.utf8-plain-text"))
        scratch.pasteboard.setString("日本語", forType: .string)

        #expect(service.stringContents(from: scratch.pasteboard) == "日本語")
        #expect(service.fallbackPlainTextContents(from: scratch.pasteboard) == "日本語")
    }

    @Test func joinsFileURLsShellEscaped() throws {
        let scratch = ScratchPasteboard()
        let service = TerminalPasteboardService()
        let fileURL = URL(fileURLWithPath: "/tmp/with space.png")
        scratch.pasteboard.clearContents()
        #expect(scratch.pasteboard.writeObjects([fileURL as NSURL]))

        let contents = try #require(service.stringContents(from: scratch.pasteboard))
        #expect(contents == "/tmp/with\\ space.png")
    }

    @Test func imageOnlyHTMLWithNoVisibleTextReturnsNil() throws {
        let scratch = ScratchPasteboard()
        let service = TerminalPasteboardService()
        scratch.pasteboard.declareTypes([.png, .html], owner: nil)
        scratch.pasteboard.setData(try tinyPNGData(), forType: .png)
        scratch.pasteboard.setString("<img src=\"x.png\"/>", forType: .html)

        #expect(service.stringContents(from: scratch.pasteboard) == nil)
    }

    @Test func hasStringIsFalseForUnsupportedLocationAndEmptyBoard() {
        let service = TerminalPasteboardService()
        #expect(!service.hasString(for: ghostty_clipboard_e(rawValue: 99)))
        #expect(service.pasteboard(for: ghostty_clipboard_e(rawValue: 99)) == nil)
    }
}

@Suite("Clipboard write capture")
struct ClipboardWriteCaptureTests {
    @Test func capturesStandardWriteWithoutTouchingPasteboard() {
        let service = TerminalPasteboardService()
        let captured = service.captureNextStandardClipboardWrite {
            service.writeString("captured-value", to: GHOSTTY_CLIPBOARD_STANDARD)
            return true
        }
        #expect(captured == "captured-value")
    }

    @Test func returnsNilWhenActionFails() {
        let service = TerminalPasteboardService()
        let captured = service.captureNextStandardClipboardWrite { false }
        #expect(captured == nil)
    }

    @Test func selectionWritesRoundTripThroughSelectionPasteboard() {
        let service = TerminalPasteboardService()
        let marker = "selection-\(UUID().uuidString)"
        service.writeString(marker, to: GHOSTTY_CLIPBOARD_SELECTION)
        let board = service.pasteboard(for: GHOSTTY_CLIPBOARD_SELECTION)
        #expect(board?.string(forType: .string) == marker)
        #expect(service.hasString(for: GHOSTTY_CLIPBOARD_SELECTION))
    }
}

@Suite("Image materialization and temp-file ownership")
struct ImageMaterializationTests {
    @Test func materializesPNGIntoOwnedTemporaryFile() throws {
        let scratchDir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let scratch = ScratchPasteboard()
        let service = TerminalPasteboardService(temporaryDirectory: scratchDir)
        scratch.pasteboard.declareTypes([.png], owner: nil)
        scratch.pasteboard.setData(try tinyPNGData(), forType: .png)

        let result = service.materializeImageFileURLIfNeeded(from: scratch.pasteboard)
        guard case .saved(let url) = result else {
            Issue.record("expected .saved, got \(result)")
            return
        }
        #expect(url.path.hasPrefix(scratchDir.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(service.isOwnedTemporaryImageFile(url))

        service.cleanupTransferredTemporaryImageFiles([url])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!service.isOwnedTemporaryImageFile(url))
    }

    @Test func rejectsOversizedImagePayload() throws {
        let scratchDir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let scratch = ScratchPasteboard()
        let service = TerminalPasteboardService(temporaryDirectory: scratchDir)
        scratch.pasteboard.declareTypes([.png], owner: nil)
        scratch.pasteboard.setData(Data(count: 10 * 1024 * 1024 + 1), forType: .png)

        #expect(
            service.materializeImageFileURLIfNeeded(from: scratch.pasteboard)
                == .rejectedImagePayload
        )
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratchDir.path)
        #expect(leftovers.isEmpty)
    }

    @Test func emptyPasteboardHasNoDecodableImagePayload() {
        let scratch = ScratchPasteboard()
        let service = TerminalPasteboardService()
        #expect(
            service.materializeImageFileURLIfNeeded(from: scratch.pasteboard)
                == .noDecodableImagePayload
        )
        #expect(
            service.materializeImageFileURLsIfNeeded(from: scratch.pasteboard)
                == .noDecodableImagePayload
        )
    }

    @Test func saveImageFileURLIfNeededYieldsToTextUnlessAssumed() throws {
        let scratchDir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let scratch = ScratchPasteboard()
        let service = TerminalPasteboardService(temporaryDirectory: scratchDir)
        // Visible rich text plus an image: stringContents resolves the text, so
        // the save path must yield to it unless the caller assumes no text.
        scratch.pasteboard.declareTypes([.string, .html, .png], owner: nil)
        scratch.pasteboard.setString("hello", forType: .string)
        scratch.pasteboard.setString("<b>hello</b>", forType: .html)
        scratch.pasteboard.setData(try tinyPNGData(), forType: .png)

        #expect(service.stringContents(from: scratch.pasteboard) == "hello")
        #expect(service.saveImageFileURLIfNeeded(from: scratch.pasteboard) == nil)

        let url = service.saveImageFileURLIfNeeded(from: scratch.pasteboard, assumeNoText: true)
        #expect(url != nil)
        if let url {
            #expect(service.isOwnedTemporaryImageFile(url))
        }
        service.cleanupAllOwnedTemporaryImageFiles()
        if let url {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func saveImageDataSanitizesHostileExtensionsAndCapsSize() throws {
        let scratchDir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let service = TerminalPasteboardService(temporaryDirectory: scratchDir)

        #expect(service.saveImageData(Data(), fileExtension: "png") == nil)
        #expect(service.saveImageData(Data(count: 10 * 1024 * 1024 + 1), fileExtension: "png") == nil)

        let escapedPath = try #require(
            service.saveImageData(try tinyPNGData(), fileExtension: "../../evil")
        )
        #expect(escapedPath.hasSuffix(".png"))
        #expect(!escapedPath.contains(".."))
        let plainPath = escapedPath.replacingOccurrences(of: "\\", with: "")
        #expect(plainPath.hasPrefix(scratchDir.path))
        #expect(service.isOwnedTemporaryImageFile(URL(fileURLWithPath: plainPath)))
        service.cleanupAllOwnedTemporaryImageFiles()
    }

    @Test func cleanupIgnoresFilesItDoesNotOwn() throws {
        let scratchDir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let service = TerminalPasteboardService(temporaryDirectory: scratchDir)
        let foreign = scratchDir.appendingPathComponent("not-owned.png")
        try Data([0x1]).write(to: foreign)

        service.cleanupTransferredTemporaryImageFiles([foreign])
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(!service.isOwnedTemporaryImageFile(foreign))
    }
}
