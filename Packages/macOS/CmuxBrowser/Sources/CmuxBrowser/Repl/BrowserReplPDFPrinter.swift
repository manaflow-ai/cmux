public import AppKit
import ObjectiveC
public import WebKit

/// Prints a web view to a paginated PDF without touching any window the
/// user sees.
///
/// AppKit runs a print operation for a window (`runModal(for:...)`), even
/// with its print and progress panels hidden. The operation here runs for a
/// private window of its own that is never ordered onto a screen, so the
/// window holding the web view, typically the user's, is never the target
/// of a print session, and a web view in no window prints too.
@MainActor
public struct BrowserReplPDFPrinter {
    /// Printing failed or produced no PDF.
    public struct Failure: Error, Equatable, Sendable {}

    /// Paper size in points.
    public let paper: CGSize
    /// Margins in points.
    public let margins: NSEdgeInsets
    /// Whether backgrounds print.
    public let printBackground: Bool

    public init(paper: CGSize, margins: NSEdgeInsets, printBackground: Bool) {
        self.paper = paper
        self.margins = margins
        self.printBackground = printBackground
    }

    /// Prints `webView` on ``paper`` with ``margins``.
    public func pdf(of webView: WKWebView) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.paperSize = paper
        printInfo.topMargin = margins.top
        printInfo.leftMargin = margins.left
        printInfo.bottomMargin = margins.bottom
        printInfo.rightMargin = margins.right
        printInfo.horizontalPagination = .automatic
        printInfo.verticalPagination = .automatic
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let preferences = webView.configuration.preferences
        let previousBackgrounds = preferences.shouldPrintBackgrounds
        preferences.shouldPrintBackgrounds = printBackground
        defer { preferences.shouldPrintBackgrounds = previousBackgrounds }

        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // WebKit's print view starts with an empty frame and prints nothing
        // until it is sized.
        operation.view?.frame = webView.bounds.isEmpty
            ? NSRect(origin: .zero, size: paper)
            : webView.bounds
        let host = Self.hostWindow()
        defer { host.close() }
        let succeeded: Bool = await withCheckedContinuation { continuation in
            let completion = Completion { continuation.resume(returning: $0) }
            objc_setAssociatedObject(operation, &Completion.key, completion, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            operation.runModal(
                for: host,
                delegate: completion,
                didRun: #selector(Completion.printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        }
        guard succeeded, let data = try? Data(contentsOf: url), !data.isEmpty else { throw Failure() }
        return data
    }

    /// A borderless, transparent window outside every screen that is never
    /// ordered in, shown in no window list and never key.
    private static func hostWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: -32_000, y: -32_000, width: 16, height: 16),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.sharingType = .none
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        return window
    }

    private final class Completion: NSObject {
        nonisolated(unsafe) static var key: UInt8 = 0
        private var completion: ((Bool) -> Void)?

        init(_ completion: @escaping (Bool) -> Void) {
            self.completion = completion
        }

        @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            let callback = completion
            completion = nil
            callback?(success)
        }
    }
}
