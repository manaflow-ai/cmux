import SwiftUI

/// One named view to render, at a fixed width, in both color schemes.
struct GalleryScene {
    let name: String
    let width: CGFloat
    let content: AnyView

    init<Content: View>(name: String, width: CGFloat = 260, @ViewBuilder content: () -> Content) {
        self.name = name
        self.width = width
        self.content = AnyView(content())
    }
}
