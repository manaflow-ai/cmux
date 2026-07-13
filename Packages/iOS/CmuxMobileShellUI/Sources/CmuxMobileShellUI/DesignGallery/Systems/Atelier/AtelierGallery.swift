#if DEBUG
import SwiftUI

/// Placeholder root for the Atelier candidate's future six-screen gallery.
struct AtelierGallery: View {
    let page: DesignGalleryPage

    var body: some View {
        Text("\(DesignGallerySystem.atelier.number) \(DesignGallerySystem.atelier.displayName) — \(page.title)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
    }
}
#endif
