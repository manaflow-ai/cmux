#if os(iOS)
import CmuxScreenKit
import SwiftUI

/// The viewer chrome's Follow button. Off: the view stays where the person
/// puts it. On: the view is a crop that follows what happens on the Mac
/// (pointer, text caret, focused window, changed pixels). While the person
/// holds the view (a pinch or a drag), the button hands it back.
struct ScreenFollowButton: View {
    let camera: any ScreenCamera

    var body: some View {
        Button(title, systemImage: symbol) { camera.toggle() }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("screen.follow")
            .accessibilityValue(camera.isFollowing ? (camera.isHeld ? "Held" : "On") : "Off")
    }

    private var title: LocalizedStringKey {
        if !camera.isFollowing { return "Follow" }
        return camera.isHeld ? "Resume Following" : "Stop Following"
    }

    private var symbol: String {
        if !camera.isFollowing { return "viewfinder" }
        return camera.isHeld ? "viewfinder.circle" : "viewfinder.circle.fill"
    }
}
#endif
