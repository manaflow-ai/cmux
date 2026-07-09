public import SwiftUI

/// The toolbar screenshot button: copies the page to the clipboard and shows a
/// transient "Copied" pill plus a checkmark glyph after a successful capture.
public struct BrowserToolbarScreenshotButton: View {
    private let snapshot: BrowserToolbarSnapshot
    private let actions: BrowserToolbarActions

    /// Creates the screenshot button from a snapshot and action bundle.
    public init(snapshot: BrowserToolbarSnapshot, actions: BrowserToolbarActions) {
        self.snapshot = snapshot
        self.actions = actions
    }

    public var body: some View {
        Button(action: actions.onScreenshot) {
            Image(systemName: snapshot.screenshotCopied ? "checkmark" : "camera")
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .cmuxSymbolRasterSize(snapshot.accessoryIconFontSize, weight: .medium)
                .foregroundStyle(snapshot.screenshotButtonColor)
                .frame(width: snapshot.buttonSize, height: snapshot.buttonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: snapshot.buttonSize, height: snapshot.buttonSize, alignment: .center)
        .disabled(!snapshot.shouldRenderWebView || snapshot.screenshotCaptureInProgress)
        .opacity(snapshot.shouldRenderWebView ? 1.0 : 0.4)
        .safeHelp(snapshot.screenshotHelp)
        .accessibilityIdentifier("BrowserScreenshotPageButton")
        .overlay(alignment: .top) {
            if snapshot.screenshotCopied {
                Label(snapshot.screenshotCopiedLabel, systemImage: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .fixedSize()
                    .offset(y: -28)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: snapshot.screenshotCopied)
    }
}
