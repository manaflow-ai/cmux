import AppKit
import ObjectiveC
import WebKit

@MainActor
protocol BrowserPDFPrintOperationRunning {
    func runPrintOperation(
        for webView: WKWebView,
        frameHandle: NSObject?,
        pdfFirstPageSize: CGSize,
        completion: @escaping () -> Void
    )
}

@MainActor
final class BrowserPDFPrintOperationRunner: BrowserPDFPrintOperationRunning {
    var hostWindowResolver: (WKWebView) -> NSWindow? = { webView in
        webView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    nonisolated init() {}

    func runPrintOperation(
        for webView: WKWebView,
        frameHandle: NSObject?,
        pdfFirstPageSize: CGSize,
        completion: @escaping () -> Void
    ) {
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        if pdfFirstPageSize.width > 0, pdfFirstPageSize.height > 0 {
            printInfo.paperSize = pdfFirstPageSize
        }
        let operation = printOperation(for: webView, frameHandle: frameHandle, printInfo: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        guard let window = hostWindowResolver(webView) else {
            completion()
            return
        }
        let printCompletion = BrowserPDFPrintCompletion(completion: completion)
        objc_setAssociatedObject(
            operation,
            &BrowserPDFPrintCompletion.printCompletionAssociationKey,
            printCompletion,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        operation.runModal(
            for: window,
            delegate: printCompletion,
            didRun: #selector(BrowserPDFPrintCompletion.printOperationDidRun(_:success:contextInfo:)),
            contextInfo: nil
        )
    }

    private func printOperation(
        for webView: WKWebView,
        frameHandle: NSObject?,
        printInfo: NSPrintInfo
    ) -> NSPrintOperation {
        let selector = NSSelectorFromString("_printOperationWithPrintInfo:forFrame:")
        if let frameHandle,
           webView.responds(to: selector),
           let implementation = webView.method(for: selector) {
            typealias PrintOperationForFrameFunction = @convention(c) (AnyObject, Selector, NSPrintInfo, NSObject) -> NSPrintOperation?
            let function = unsafeBitCast(implementation, to: PrintOperationForFrameFunction.self)
            if let operation = function(webView, selector, printInfo, frameHandle) {
                return operation
            }
        }
        return webView.printOperation(with: printInfo)
    }
}

private final class BrowserPDFPrintCompletion: NSObject {
    fileprivate static var printCompletionAssociationKey: UInt8 = 0

    private let completion: () -> Void

    init(completion: @escaping () -> Void) {
        self.completion = completion
    }

    @objc func printOperationDidRun(
        _ printOperation: NSPrintOperation,
        success: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        let completion = self.completion
        objc_setAssociatedObject(
            printOperation,
            &Self.printCompletionAssociationKey,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        completion()
    }
}
