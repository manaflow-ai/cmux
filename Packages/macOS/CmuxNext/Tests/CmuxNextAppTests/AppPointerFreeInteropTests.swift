import AppKit
@testable import CmuxNextApp
import CmuxNextCompatAppKit
import Darwin
import Foundation
import Testing

/// The app's C and Objective-C interop after p10-stability-072 (strict memory safety): the shared
/// helpers that hold the one `unsafe` call for many call sites, and the sites rewritten without a
/// pointer (the opaque-picture sample, the run marker's write, the signal relay's handler).
@MainActor @Suite(.timeLimit(.minutes(1))) struct AppPointerFreeInteropTests {
    @Test func entryKindTellsAFolderAFileAndNothingApartAndFollowsALink() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let files = FileManager.default
        #expect(files.entryKind(atPath: directory.path) == .directory)
        #expect(files.entryKind(atPath: file.path) == .nonDirectory)
        #expect(files.entryKind(atPath: directory.appendingPathComponent("missing").path) == nil)
        #expect(files.entryKind(atPath: link.path) == .directory)
        #expect(files.directoryExists(atPath: directory.path))
        #expect(!files.directoryExists(atPath: file.path))
        #expect(FileManager.checked.directoryExists(atPath: link.path))
        #expect(!FileManager.checked.directoryExists(atPath: file.path))
    }

    @Test func theBestCGImageIsTheImagesOwnBitmap() throws {
        let rep = try #require(NSBitmapImageRep.ownedRGBA(width: 4, height: 2))
        #expect(rep.pixelsWide == 4)
        #expect(rep.pixelsHigh == 2)
        #expect(rep.samplesPerPixel == 4)
        #expect(rep.hasAlpha)
        let image = NSImage(size: NSSize(width: 4, height: 2))
        image.addRepresentation(rep)
        let cgImage = try #require(image.bestCGImage)
        #expect(cgImage.width == 4)
        #expect(cgImage.height == 2)
    }

    @Test func anOwnedBitmapKeepsTheAskedRowBytesAndWhatIsDrawn() throws {
        let context = try #require(CGContext.bitmapOwningPixels(width: 6, height: 2, bytesPerRow: 6 * 4,
                                                                space: CGColorSpaceCreateDeviceRGB(),
                                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        #expect(context.bytesPerRow == 24)
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 6, height: 2))
        let image = try #require(context.makeImage())
        #expect(image.width == 6)
        let color = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: 2, y: 1))
        #expect(color.blueComponent > 0.99)
        #expect(color.redComponent < 0.01)
    }

    @Test func theOpaqueSampleReadsThePixelsBackWithoutTheContextsBuffer() throws {
        let opaque = try Self.filled(alpha: 1), clear = try Self.filled(alpha: 0)
        #expect(HibernationSnapshots.isOpaque(opaque))
        #expect(!HibernationSnapshots.isOpaque(clear))
        let half = try #require(CGContext.bitmapOwningPixels(width: 64, height: 64, space: CGColorSpaceCreateDeviceRGB(),
                                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        half.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        half.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        let halfClear = try #require(half.makeImage())
        #expect(!HibernationSnapshots.isOpaque(halfClear))
    }

    @Test func theRunMarkerWriteReplacesTheFileAndLeavesNoTemporary() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("run.json")
        try RunMarkerFile.replaceAtomically(Data("first".utf8), to: file)
        try RunMarkerFile.replaceAtomically(Data("second, longer".utf8), to: file)
        #expect(try Data(contentsOf: file) == Data("second, longer".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["run.json"])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func aRunMarkerWriteIntoAMissingFolderThrows() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString)/run.json")
        #expect(throws: (any Error).self) { try RunMarkerFile.replaceAtomically(Data("x".utf8), to: missing) }
    }

    @Test func aSaveErrorNamesItsStepAndTheSystemsText() {
        #expect(FileDocument.WriteError(step: "open", code: ENOENT).description == "open: No such file or directory")
        #expect(FileDocument.WriteError(step: "rename", code: EACCES).description == "rename: Permission denied")
    }

    @Test func aWatchedFolderIsTheKernelsPath() {
        #expect(FolderWatcherPath.real(URL(fileURLWithPath: "/tmp")) == "/private/tmp")
        let missing = "/nonexistent-\(UUID().uuidString)"
        #expect(FolderWatcherPath.real(URL(fileURLWithPath: missing)) == missing)
    }

    @Test func aRelayedSignalIsCaughtSoItDoesNotEndTheProcess() {
        let relay = SignalRelay(signals: [SIGUSR2]) { _ in }
        defer { relay.cancel() }
        // Uncaught, SIGUSR2's default action would end the test process here.
        #expect(raise(SIGUSR2) == 0)
        // A second install (after Chromium's start) keeps it caught.
        relay.catchSignals()
        #expect(raise(SIGUSR2) == 0)
        // The relay's handler is the one in place, not the default.
        let installed = Darwin.signal(SIGUSR2, SIG_DFL)
        #expect(installed != nil)
        relay.catchSignals()
    }

    private static func filled(alpha: CGFloat) throws -> CGImage {
        let context = try #require(CGContext.bitmapOwningPixels(width: 40, height: 40, space: CGColorSpaceCreateDeviceRGB(),
                                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: alpha)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        return try #require(context.makeImage())
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("app-pointer-free-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath()
    }
}
