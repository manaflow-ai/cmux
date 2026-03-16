//
//  CmuxFieldEditorOwningWebViewBox.swift
//  cmux
//
//  Created by Gale Williams on 3/16/26.
//

import AppKit

// MARK: - CmuxFieldEditorOwningWebViewBox

final class CmuxFieldEditorOwningWebViewBox: NSObject {
    // MARK: Properties

    weak var webView: CmuxWebView?

    // MARK: Lifecycle

    init(webView: CmuxWebView?) {
        self.webView = webView
    }
}
