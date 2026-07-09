public import AppKit
public import SwiftUI

/// The `NSHostingView` that hosts the file-preview PDF chrome SwiftUI controls
/// (sidebar menu, zoom controls) as an overlay above the PDF view.
///
/// It accepts the first mouse so a click that also focuses the window still
/// activates the chrome control in a single press, matching the standalone
/// overlay-button behavior. ``FilePreviewPDFChromeHostView`` recognizes this
/// type during hit testing to route interactive hits into the hosted controls.
public final class FilePreviewPDFChromeHostingView: NSHostingView<AnyView> {
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
