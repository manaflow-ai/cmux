#if DEBUG
import SwiftUI

/// Placeholder root for the Signal candidate's future six-screen gallery.
struct SignalGallery: View {
    let page: DesignGalleryPage

    var body: some View {
        Text("\(DesignGallerySystem.signal.number) \(DesignGallerySystem.signal.displayName) — \(page.title)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
    }
}
#endif
