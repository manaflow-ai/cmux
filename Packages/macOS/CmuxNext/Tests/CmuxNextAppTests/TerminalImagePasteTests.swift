import AppKit
import Testing
@testable import CmuxNextTerminal

/// A Cmd-V with an image on the clipboard pastes the image's saved path, as in
/// the shipping cmux, so a terminal agent receives the picture.
///
/// The decisions run on ``TerminalPasteboardContents``, a value read from the
/// pasteboard once, so the suite needs no pasteboard server: a fleet test step
/// has none, and there every real `NSPasteboard` read returned nil (step
/// 9222062d, 2026-10-20: even a plain string read back nil).
@MainActor
@Suite struct TerminalImagePasteTests {
    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("image-paste-\(UUID().uuidString)")
    }

    private func pngData() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func imageOnlyClipboardPastesSavedFilePath() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = pngData()
        let contents = TerminalPasteboardContents(png: data)

        let text = try #require(TerminalPasteboard.pasteTextSavingImage(from: contents, directory: directory))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(file.hasPrefix(TerminalPasteboard.imageFilenamePrefix) && file.hasSuffix(".png"))
        #expect(text == TerminalPasteboard.shellEscaped(directory.appendingPathComponent(file).path))
        #expect(try Data(contentsOf: directory.appendingPathComponent(file)) == data)
    }

    @Test func jpegIsSavedAsIs() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let text = try #require(TerminalPasteboard.pasteTextSavingImage(from: TerminalPasteboardContents(jpeg: jpeg),
                                                                        directory: directory))
        #expect(text.hasSuffix(".jpg"))
    }

    @Test func tiffImageIsSavedAsPNG() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tiff = try #require(NSImage(data: pngData())?.tiffRepresentation)
        let contents = TerminalPasteboardContents(tiff: tiff)

        #expect(contents.hasImage)
        let text = try #require(TerminalPasteboard.pasteTextSavingImage(from: contents, directory: directory))
        #expect(text.hasSuffix(".png"))
        let file = try #require(try FileManager.default.contentsOfDirectory(atPath: directory.path).first)
        let saved = try Data(contentsOf: directory.appendingPathComponent(file))
        #expect(saved.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func textWinsOverImageAndWritesNoFile() {
        let directory = scratchDirectory()
        let contents = TerminalPasteboardContents(string: "hello", png: pngData())

        #expect(TerminalPasteboard.pasteTextSavingImage(from: contents, directory: directory) == "hello")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func fileURLsWinAsShellEscapedPaths() {
        let contents = TerminalPasteboardContents(fileURLs: [URL(fileURLWithPath: "/tmp/a b.png")],
                                                  string: "ignored", png: pngData())
        #expect(TerminalPasteboard.pasteText(from: contents) == "/tmp/a\\ b.png")
    }

    /// An image of any size is saved and its path pasted; the paste once
    /// dropped images over 10 MiB with nothing pasted and no message.
    @Test func anImageOverTenMebibytesIsSavedWhole() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var big = pngData()
        big.append(Data(count: 10 * 1024 * 1024 + 1))
        let contents = TerminalPasteboardContents(png: big)

        let text = try #require(TerminalPasteboard.pasteTextSavingImage(from: contents, directory: directory))
        let file = try #require(try FileManager.default.contentsOfDirectory(atPath: directory.path).first)
        #expect(text == TerminalPasteboard.shellEscaped(directory.appendingPathComponent(file).path))
        #expect(try Data(contentsOf: directory.appendingPathComponent(file)) == big)
    }

    @Test func emptyClipboardPastesNothing() {
        let contents = TerminalPasteboardContents()
        #expect(!contents.hasImage)
        #expect(TerminalPasteboard.pasteTextSavingImage(from: contents, directory: scratchDirectory()) == nil)
    }

    @Test func onlyCommandVIsTheUserPasteChord() {
        func key(_ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: 9)!
        }
        #expect(TerminalClipboardRequests.isPasteChord(key("v", .command)))
        #expect(!TerminalClipboardRequests.isPasteChord(key("v", [.command, .shift])))
        #expect(!TerminalClipboardRequests.isPasteChord(key("v", .control)))
        #expect(!TerminalClipboardRequests.isPasteChord(key("c", .command)))
    }
}
