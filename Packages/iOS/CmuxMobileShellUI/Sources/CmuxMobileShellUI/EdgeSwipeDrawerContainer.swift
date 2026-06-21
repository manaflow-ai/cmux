#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Hosts `content` with a left-edge-swipe nav drawer overlay.
///
/// The edge swipe is driven by a UIKit `UIScreenEdgePanGestureRecognizer` (the same
/// system recognizer behind the interactive back gesture and Control Center), NOT a
/// SwiftUI `DragGesture`. That matters: a SwiftUI drag on an overlay strip competes
/// with the workspace list's own scroll + row swipe actions and feels broken, while
/// the screen-edge recognizer has edge priority and coordinates with `UIScrollView`
/// automatically — so the drawer opens cleanly and the list is untouched away from
/// the very edge. The drag is interactive (the panel tracks the finger); a tappable
/// affordance the caller renders (the list's leading toolbar button) flips `isOpen`
/// as the primary, accessible entry.
struct EdgeSwipeDrawerContainer<Content: View, Drawer: View>: View {
    @Binding var isOpen: Bool
    /// Whether the left-edge swipe is armed. The caller disables it anywhere the
    /// left edge already means something — a pushed detail screen (system back
    /// swipe) or the iPad split layout (`NavigationSplitView`'s own sidebar
    /// gesture) — so the drawer's edge swipe only fires on the compact root list.
    /// The ☰ toolbar button opens the drawer in every state regardless.
    var isEdgeSwipeEnabled: Bool = true
    var drawerMaxWidth: CGFloat = 360
    @ViewBuilder var content: () -> Content
    @ViewBuilder var drawer: () -> Drawer

    /// Live open fraction (0 closed … 1 open) while a screen-edge pan is in flight;
    /// `nil` when not dragging, so the offset is driven purely by `isOpen`.
    @State private var dragFraction: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let width = min(drawerMaxWidth, geo.size.width * 0.86)
            let fraction = dragFraction ?? (isOpen ? 1 : 0)
            ZStack(alignment: .leading) {
                content()
                    // Install the screen-edge recognizer on the hosting view so it
                    // coordinates with the scroll view; disabled while open (the
                    // scrim/panel own interaction then).
                    .background(
                        ScreenEdgePanInstaller(
                            isEnabled: isEdgeSwipeEnabled && !isOpen,
                            onChanged: { translation in
                                dragFraction = min(1, max(0, translation / width))
                            },
                            onEnded: { translation, velocity in
                                let shouldOpen = velocity > 300 || (translation / width) > 0.4
                                dragFraction = nil
                                withAnimation(.snappy(duration: 0.25)) { isOpen = shouldOpen }
                            }
                        )
                    )

                if fraction > 0.001 {
                    Color.black.opacity(0.35 * fraction)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.25)) { isOpen = false }
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(
                            L10n.string("mobile.drawer.close", defaultValue: "Close menu"))
                }

                drawer()
                    .frame(width: width, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(.regularMaterial)
                    .clipShape(.rect(bottomTrailingRadius: 18, topTrailingRadius: 18))
                    .shadow(color: .black.opacity(0.25 * fraction), radius: 16, x: 4, y: 0)
                    .offset(x: -width * (1 - fraction))
                    // Drag the open panel back toward the edge to close.
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onEnded { value in
                                if value.translation.width < -44 {
                                    withAnimation(.snappy(duration: 0.25)) { isOpen = false }
                                }
                            }
                    )
                    .accessibilityHidden(fraction < 0.5)
            }
            // Only animate the discrete open/close; the interactive drag already
            // moves continuously via `dragFraction`.
            .animation(dragFraction == nil ? .snappy(duration: 0.25) : nil, value: isOpen)
        }
    }
}

/// Installs a `UIScreenEdgePanGestureRecognizer(.left)` on the SwiftUI hosting view
/// (its `superview`), so left-edge pans are recognized with system edge priority and
/// coordinate with any enclosing scroll view. Reports the live translation/velocity
/// back to SwiftUI. A zero-size background view; it never blocks content touches.
private struct ScreenEdgePanInstaller: UIViewRepresentable {
    var isEnabled: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.recognizer?.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    final class Coordinator: NSObject {
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void
        weak var recognizer: UIScreenEdgePanGestureRecognizer?

        init(
            onChanged: @escaping (CGFloat) -> Void, onEnded: @escaping (CGFloat, CGFloat) -> Void
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func handlePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
            let translation = max(0, gesture.translation(in: gesture.view).x)
            switch gesture.state {
            case .changed:
                onChanged(translation)
            case .ended, .cancelled, .failed:
                onEnded(translation, gesture.velocity(in: gesture.view).x)
            default:
                break
            }
        }
    }

    /// Attaches the recognizer to its `superview` (the hosting view) once it is in a
    /// window, scoping the gesture to this container's subtree.
    final class InstallerView: UIView {
        weak var coordinator: Coordinator?
        private var installed = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard !installed, window != nil, let target = superview, let coordinator else { return }
            let recognizer = UIScreenEdgePanGestureRecognizer(
                target: coordinator, action: #selector(Coordinator.handlePan(_:)))
            recognizer.edges = .left
            target.addGestureRecognizer(recognizer)
            coordinator.recognizer = recognizer
            installed = true
        }
    }
}
#endif
