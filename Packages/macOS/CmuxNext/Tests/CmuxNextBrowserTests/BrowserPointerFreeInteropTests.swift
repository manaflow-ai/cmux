import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing
import WebKit

/// The browser's C and Objective-C interop after p10-stability-068 (strict memory safety): the
/// owned bitmap and rounded path helpers that replace pointer-taking calls, the download file
/// checks marked `unsafe`, and the Web Inspector lookup that no longer goes through `Unmanaged`.
@MainActor @Suite(.timeLimit(.minutes(1))) struct BrowserPointerFreeInteropTests {
    @Test func anOwnedBitmapHasTheAskedSizeAndKeepsWhatIsDrawn() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext.ownedBitmap(width: 7, height: 3, space: space,
                                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 7, height: 3))
        let image = try #require(context.makeImage())
        #expect(image.width == 7)
        #expect(image.height == 3)
        let color = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: 3, y: 1)?.usingColorSpace(.sRGB))
        #expect(color.redComponent > 0.99)
        #expect(color.greenComponent < 0.01)
    }

    @Test func aRoundedPathFillsTheRectButNotItsCorners() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 40)
        let path = CGPath.rounded(rect, radius: 12)
        #expect(path.boundingBox == rect)
        #expect(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
        #expect(path.contains(CGPoint(x: rect.minX + 1, y: rect.midY)))
        #expect(!path.contains(CGPoint(x: rect.minX + 1, y: rect.minY + 1)))
        #expect(!path.contains(CGPoint(x: rect.maxX - 1, y: rect.maxY - 1)))
    }

    @Test func aDanglingSymlinkIsTakenAndAMissingNameIsFree() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dangling = directory.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: directory.appendingPathComponent("nowhere"))
        #expect(DownloadDestination.entryExists(dangling))
        #expect(!DownloadDestination.entryExists(directory.appendingPathComponent("missing")))
    }

    @Test func anExclusiveMoveNeverReplacesWhatIsThere() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let taken = directory.appendingPathComponent("taken")
        let free = directory.appendingPathComponent("free")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: taken)
        #expect(throws: POSIXError(.EEXIST)) { try BrowserDownloadPlacement.moveExclusively(source, to: taken) }
        #expect(try Data(contentsOf: taken) == Data("old".utf8))
        try BrowserDownloadPlacement.moveExclusively(source, to: free)
        #expect(try Data(contentsOf: free) == Data("new".utf8))
        #expect(!DownloadDestination.entryExists(source))
    }

    /// The `_inspector` lookup is KVC behind `responds(to:)`: a hidden inspector reads as not
    /// visible, with no undefined-key exception.
    @Test func aWebViewsInspectorReadsAsHiddenUntilShown() {
        let webView = WKWebView(frame: .zero)
        #expect(!WebKitInspector(webView: webView).isVisible)
    }

    /// The watch's read (`WebKitInspectorWatch`) shares the same KVC lookup and, unlike the
    /// inspector's own actions, does not make the web view inspectable as a side effect.
    @Test func theWatchReadOfAnInspectorIsHiddenAndLeavesTheWebViewUninspectable() {
        let webView = WKWebView(frame: .zero)
        webView.isInspectable = false
        #expect(!WebKitInspector.isVisible(of: webView))
        #expect(!webView.isInspectable)
        #expect(!WebKitInspector(webView: webView).isVisible)
        #expect(webView.isInspectable)
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-pointer-free-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
