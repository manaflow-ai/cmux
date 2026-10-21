#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileDesign
import SwiftUI
import UIKit

/// An image opened full screen from the transcript: pinch or double-tap to zoom (to the
/// tapped point), pan while zoomed, swipe down at the fitted size or Close to close, Share.
public struct ImageViewerItem: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let data: Data

    public init(id: String, name: String, data: Data) {
        self.id = id
        self.name = name
        self.data = data
    }
}

struct FullScreenImageViewer: View {
    let item: ImageViewerItem
    @Environment(\.dismiss) private var dismiss
    @State private var drag: CGFloat = 0

    var body: some View {
        let image = UIImage(data: item.data)
        NavigationStack {
            // Pinch, double-tap to the tapped point and pan come from the UIScrollView zoom
            // host; the downward swipe to close is reported only at the fitted size.
            ZoomableImage(image: image, label: "Image, \(item.name)", onDismissDrag: { translation, ended in
                if ended {
                    if translation > 120 { dismiss() } else { withAnimation(.cmuxMobileSnap) { drag = 0 } }
                } else {
                    drag = translation
                }
            })
                .offset(y: drag)
                .ignoresSafeArea(edges: .bottom)
                .background(Color.black.opacity(1 - min(drag / 400, 0.6)).ignoresSafeArea())
                .navigationTitle(item.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                    if let image {
                        ToolbarItem(placement: .topBarTrailing) {
                            ShareLink(item: Image(uiImage: image), preview: SharePreview(item.name, image: Image(uiImage: image))) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Share")
                        }
                    }
                }
        }
        // VoiceOver stays inside the viewer while it is open.
        .accessibilityAddTraits(.isModal)
        .preferredColorScheme(.dark)
    }
}
#endif
