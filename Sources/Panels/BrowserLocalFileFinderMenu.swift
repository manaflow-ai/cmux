import Foundation
import SwiftUI

/// Adds the shared open-externally and Finder reveal actions when the browser is displaying a local file.
struct BrowserLocalFileFinderMenu: View {
    let fileURL: URL?

    var body: some View {
        if let fileURL, fileURL.isFileURL {
            Divider()
            Button {
                FileExternalOpenAction.openDefault(fileURL: fileURL)
            } label: {
                Label(
                    FileExternalOpenText.openExternally,
                    systemImage: "arrow.up.forward.app"
                )
            }
            .accessibilityIdentifier("BrowserOpenLocalFileExternally")
            Button {
                FileExternalOpenAction.revealInFinder(fileURL: fileURL)
            } label: {
                Label(
                    FileExternalOpenText.revealInFinder,
                    systemImage: "folder"
                )
            }
            .accessibilityIdentifier("BrowserRevealLocalFileInFinder")
        }
    }
}
