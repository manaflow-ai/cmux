import AppKit
import CmuxBrowser
import Foundation
import WebKit

class BrowserPDFPreviewActionUIDelegate: NSObject, WKUIDelegate {
    var downloadsFileManager: FileManager = .default
    var downloadsDefaults: UserDefaults = .standard
    var printOperationRunner: any BrowserPDFPrintOperationRunning = BrowserPDFPrintOperationRunner()

    /// WebKit delivers the Pointer Lock API permission handshake through this
    /// private UI delegate selector. WebKit has already checked that the page
    /// request came from a user activation before calling the embedder.
    @objc(_webViewDidRequestPointerLock:completionHandler:)
    @MainActor
    func webView(
        _ webView: WKWebView,
        didRequestPointerLock completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }

    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    @MainActor
    func webView(
        _ webView: WKWebView,
        saveDataToFile data: Data,
        suggestedFilename: String,
        mimeType: String,
        originatingURL: URL
    ) {
        guard !data.isEmpty else {
            #if DEBUG
            cmuxDebugLog("browser.pdfPreview.save stage=rejectEmptyData")
            #endif
            return
        }
        guard let downloadDelegate = (webView as? CmuxWebView)?.cmuxDownloadDelegate as? BrowserDownloadDelegate else {
            #if DEBUG
            cmuxDebugLog("browser.pdfPreview.save stage=rejectMissingDelegate")
            #endif
            return
        }
        #if DEBUG
        cmuxDebugLog("browser.pdfPreview.save stage=accepted")
        #endif
        downloadDelegate.savePDFPreviewData(
            data,
            suggestedFilename: suggestedFilename,
            mimeType: mimeType,
            sourceURL: originatingURL,
            fileManager: downloadsFileManager,
            defaults: downloadsDefaults
        )
    }

    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    @MainActor
    func webView(
        _ webView: WKWebView,
        printFrame frameHandle: NSObject,
        pdfFirstPageSize size: CGSize,
        completionHandler: @escaping () -> Void
    ) {
        #if DEBUG
        cmuxDebugLog("browser.pdfPreview.print stage=accepted")
        #endif
        printOperationRunner.runPrintOperation(
            for: webView,
            frameHandle: frameHandle,
            pdfFirstPageSize: size,
            completion: completionHandler
        )
    }
}
