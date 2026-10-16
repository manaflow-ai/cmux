import AppKit
import CmuxBrowser
import CmuxFoundation
import SwiftUI

/// What a browser pane asks the user to do before its page comes back.
enum BrowserPageRecoveryPrompt {
    /// The visible page's WebContent process died.
    case crashed
    /// The page was unloaded to save memory and automatic restore is off
    /// (https://github.com/manaflow-ai/cmux/issues/9561). The snapshot is the
    /// page as it looked when the pane was hidden.
    case unloaded(snapshot: BrowserPageSnapshotImage?)
}

/// Covers a browser pane whose page is gone until the user brings it back.
struct BrowserPageRecoveryOverlay: View {
    let prompt: BrowserPageRecoveryPrompt
    let backgroundColor: NSColor
    let action: () -> Void

    var body: some View {
        switch prompt {
        case .crashed:
            ZStack {
                Color(nsColor: backgroundColor)
                    .opacity(0.92)
                Button(action: action) {
                    Label(
                        String(localized: "browser.error.reload", defaultValue: "Reload"),
                        systemImage: "arrow.clockwise"
                    )
                    .cmuxFont(size: 13, weight: .medium)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .safeHelp(String(localized: "browser.reload", defaultValue: "Reload"))
                .accessibilityIdentifier("BrowserWebContentRecoveryButton")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unloaded(let snapshot):
            ZStack {
                Color(nsColor: backgroundColor)
                if let snapshot, let image = NSImage(data: snapshot.jpegData) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: snapshot.pointSize.width, height: snapshot.pointSize.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .opacity(0.35)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 10) {
                    Text(String(
                        localized: "browser.discard.unloadedMessage",
                        defaultValue: "This page was unloaded to save memory."
                    ))
                    .cmuxFont(size: 13)
                    .foregroundStyle(.secondary)
                    Button(action: action) {
                        Label(
                            String(localized: "browser.discard.restore", defaultValue: "Restore"),
                            systemImage: "arrow.counterclockwise"
                        )
                        .cmuxFont(size: 13, weight: .medium)
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .accessibilityIdentifier("BrowserUnloadedPageRestoreButton")
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }
}
