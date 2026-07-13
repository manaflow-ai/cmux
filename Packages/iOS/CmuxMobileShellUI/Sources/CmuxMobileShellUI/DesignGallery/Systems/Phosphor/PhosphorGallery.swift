#if DEBUG
import SwiftUI

/// Placeholder root for the Phosphor candidate's future six-screen gallery.
struct PhosphorGallery: View {
    let page: DesignGalleryPage

    var body: some View {
        Text("\(DesignGallerySystem.phosphor.number) \(DesignGallerySystem.phosphor.displayName) — \(page.title)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
    }
}
#endif
