public import AppKit
public import SwiftUI

/// `NSHostingView` for the floating PDF chrome that accepts the first mouse
/// click, so the chrome controls activate without first focusing the preview.
public final class FilePreviewPDFChromeHostingView: NSHostingView<AnyView> {
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
