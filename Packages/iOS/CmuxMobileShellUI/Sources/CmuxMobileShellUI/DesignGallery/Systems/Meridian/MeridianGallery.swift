#if DEBUG
import SwiftUI

/// Placeholder root for the Meridian candidate's future six-screen gallery.
struct MeridianGallery: View {
    let page: DesignGalleryPage

    var body: some View {
        Text("\(DesignGallerySystem.meridian.number) \(DesignGallerySystem.meridian.displayName) — \(page.title)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
    }
}
#endif
