import AppKit
import Foundation
import ObjectiveC
import os
import WebKit

nonisolated private let browserPDFPreviewLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "browser.pdfPreview"
)

private struct BrowserPDFPreviewWriteError: Error, Sendable {}

private actor BrowserPDFPreviewFileWriter {
    static let shared = BrowserPDFPreviewFileWriter()

    func write(data: Data, to destURL: URL) -> Bool {
        do {
            try? FileManager.default.removeItem(at: destURL)
            try data.write(to: destURL, options: .atomic)
            browserPDFPreviewLogger.notice("PDF preview download saved path=\(destURL.path, privacy: .private)")
            return true
        } catch {
            browserPDFPreviewLogger.error("PDF preview download save failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}

@MainActor
private enum BrowserPDFPreviewFallbackDownloadDelegate {
    static let shared = BrowserDownloadDelegate()
}

extension BrowserDownloadDelegate {
    func savePDFPreviewData(
        _ data: Data,
        suggestedFilename: String?,
        mimeType: String?,
        originatingURL: URL?,
        presentingWindow: NSWindow?
    ) {
        let safeFilename = Self.filename(
            from: suggestedFilename ?? "",
            fallbackURL: originatingURL,
            mimeType: mimeType ?? "application/pdf"
        )

        onDownloadStarted?(safeFilename)
        onDownloadReadyToSave?()

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = safeFilename
        savePanel.canCreateDirectories = true
        savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        let handleResult: (NSApplication.ModalResponse) -> Void = { result in
            guard result == .OK, let destURL = savePanel.url else {
                return
            }

            Task { @MainActor in
                let didWrite = await BrowserPDFPreviewFileWriter.shared.write(data: data, to: destURL)
                guard !didWrite else { return }
                self.onDownloadSaveFailed?(BrowserPDFPreviewWriteError())
            }
        }

        presentSavePanel(savePanel, presentingWindow: presentingWindow, completionHandler: handleResult)
    }
}

enum BrowserPDFPreviewActionSupport {
    private static var printCompletionKey: UInt8 = 0

    private final class PrintCompletion: NSObject {
        private let completionHandler: () -> Void

        init(completionHandler: @escaping () -> Void) {
            self.completionHandler = completionHandler
        }

        @objc func printOperationDidRun(
            _ printOperation: NSPrintOperation,
            success: Bool,
            contextInfo: UnsafeMutableRawPointer?
        ) {
            objc_setAssociatedObject(
                printOperation,
                &BrowserPDFPreviewActionSupport.printCompletionKey,
                nil,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            completionHandler()
        }
    }

    static func saveDataToFile(
        _ data: NSData?,
        suggestedFilename: String?,
        mimeType: String?,
        originatingURL: URL?,
        from webView: WKWebView,
        downloadDelegate: BrowserDownloadDelegate?
    ) {
        guard let data, data.length > 0 else {
#if DEBUG
            cmuxDebugLog("browser.pdfPreview.save skipped reason=emptyData")
#endif
            return
        }

        Task { @MainActor in
            let delegate = downloadDelegate ?? BrowserPDFPreviewFallbackDownloadDelegate.shared
            delegate.savePDFPreviewData(
                data as Data,
                suggestedFilename: suggestedFilename,
                mimeType: mimeType,
                originatingURL: originatingURL ?? webView.url,
                presentingWindow: webView.window
            )
        }
    }

    static func printFrame(
        from webView: WKWebView,
        pdfFirstPageSize: CGSize,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
            if pdfFirstPageSize.width > 0, pdfFirstPageSize.height > 0 {
                printInfo.paperSize = pdfFirstPageSize
            }

            let printOperation = webView.printOperation(with: printInfo)
            printOperation.showsPrintPanel = true
            printOperation.showsProgressPanel = true
            printOperation.jobTitle = [
                webView.title,
                webView.url?.lastPathComponent,
                webView.url?.host
            ].compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }.first ?? String(localized: "browser.pdfPreview.printJobTitle", defaultValue: "PDF")

            guard let window = webView.window ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                completionHandler()
                return
            }

            let completion = PrintCompletion(completionHandler: completionHandler)
            objc_setAssociatedObject(
                printOperation,
                &printCompletionKey,
                completion,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            printOperation.runModal(
                for: window,
                delegate: completion,
                didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        }
    }
}
