import CmuxMobileSupport
import SwiftUI

/// Hosts `content` with a left-edge-swipe nav drawer overlay.
///
/// The drawer slides in from the leading edge over a dimming scrim. Two ways to
/// open it: a tappable affordance the caller renders (the workspace list's leading
/// toolbar button — the primary, always-reliable, accessible entry) which flips
/// `isOpen`, and a narrow leading-edge drag strip (secondary, "swipe from the left
/// edge" like the home screen). The strip is intentionally thin so it mostly stays
/// clear of the workspace list's own row swipe actions; closing is via the scrim
/// tap, a leftward drag on the panel, or any item that flips `isOpen` back.
///
/// Pure overlay sibling of the layout (not inside the list's `List`/`ForEach`), so
/// the drawer may hold observable state without crossing the snapshot boundary.
struct EdgeSwipeDrawerContainer<Content: View, Drawer: View>: View {
    @Binding var isOpen: Bool
    var drawerMaxWidth: CGFloat = 360
    @ViewBuilder var content: () -> Content
    @ViewBuilder var drawer: () -> Drawer

    var body: some View {
        GeometryReader { geo in
            let width = min(drawerMaxWidth, geo.size.width * 0.86)
            ZStack(alignment: .leading) {
                content()

                // Secondary open affordance: a thin leading-edge drag strip, present
                // only while closed. A rightward horizontal drag opens the drawer.
                if !isOpen {
                    Color.clear
                        .frame(width: 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 18)
                                .onEnded { value in
                                    if value.translation.width > 44,
                                       abs(value.translation.height) < 60 {
                                        isOpen = true
                                    }
                                }
                        )
                }

                if isOpen {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { isOpen = false }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(
                            L10n.string("mobile.drawer.close", defaultValue: "Close menu"))
                        .transition(.opacity)
                }

                drawer()
                    .frame(width: width, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(.regularMaterial)
                    .clipShape(.rect(bottomTrailingRadius: 18, topTrailingRadius: 18))
                    .shadow(color: .black.opacity(isOpen ? 0.25 : 0), radius: 16, x: 4, y: 0)
                    .offset(x: isOpen ? 0 : -(width + 32))
                    .gesture(
                        DragGesture(minimumDistance: 16)
                            .onEnded { value in
                                if value.translation.width < -44 { isOpen = false }
                            }
                    )
                    .accessibilityHidden(!isOpen)
            }
            .animation(.snappy(duration: 0.28), value: isOpen)
        }
    }
}
