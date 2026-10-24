import AppKit
import SwiftUI

/// `Image(src)`: a file inside the app bundle (never the network).
struct AppSceneBundleImage: View {
    let path: String?
    @Environment(\.appBundleDirectory) private var directory
    @Environment(\.appBundleImages) private var images

    var body: some View {
        if let image = images?.image(path: path, in: directory) {
            Image(nsImage: image).resizable().scaledToFit()
        }
    }
}
