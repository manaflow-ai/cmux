import AppKit
import Testing
@testable import CmuxNextTerminal

/// A Cmd-V with an image on the clipboard pastes the image's saved path, as in
/// the shipping cmux, so a terminal agent receives the picture.
@MainActor
@Suite struct TerminalImagePasteTests {
    private func scratch() -> (NSPasteboard, URL) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux-next-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("image-paste-\(UUID().uuidString)")
        return (pasteboard, directory)
    }

    private func pngData() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func imageOnlyClipboardPastesSavedFilePath() throws {
        let (pasteboard, directory) = scratch()
        defer { try? FileManager.default.removeItem(at: directory); pasteboard.releaseGlobally() }
        let data = pngData()
        pasteboard.setData(data, forType: .png)

        let text = try #require(TerminalPasteboard.pasteTextSavingImage(from: pasteboard, directory: directory))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(file.hasPrefix(TerminalPasteboard.imageFilenamePrefix) && file.hasSuffix(".png"))
        #expect(text == TerminalPasteboard.shellEscaped(directory.appendingPathComponent(file).path))
        #expect(try Data(contentsOf: directory.appendingPathComponent(file)) == data)
    }

    @Test func tiffImageIsSavedAsPNG() throws {
        let (pasteboard, directory) = scratch()
        defer { try? FileManager.default.removeItem(at: directory); pasteboard.releaseGlobally() }
        let tiff = try #require(NSImage(data: pngData())?.tiffRepresentation)
        pasteboard.setData(tiff, forType: .tiff)

        #expect(TerminalPasteboard.hasImage(pasteboard))
        let text = try #require(TerminalPasteboard.pasteTextSavingImage(from: pasteboard, directory: directory))
        #expect(text.hasSuffix(".png"))
    }

    @Test func textWinsOverImageAndWritesNoFile() {
        let (pasteboard, directory) = scratch()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string, .png], owner: nil)
        pasteboard.setString("hello", forType: .string)
        pasteboard.setData(pngData(), forType: .png)

        #expect(TerminalPasteboard.pasteTextSavingImage(from: pasteboard, directory: directory) == "hello")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func emptyClipboardPastesNothing() {
        let (pasteboard, directory) = scratch()
        defer { pasteboard.releaseGlobally() }
        #expect(!TerminalPasteboard.hasImage(pasteboard))
        #expect(TerminalPasteboard.pasteTextSavingImage(from: pasteboard, directory: directory) == nil)
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
