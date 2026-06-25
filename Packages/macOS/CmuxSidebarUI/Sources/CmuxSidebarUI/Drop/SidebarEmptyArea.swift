public import SwiftUI
public import CmuxAppKitSupportUI
internal import CmuxSidebar

/// The blank hit target below the workspace sidebar's tab list.
///
/// Double-clicking the strip activates the empty area (the app creates a new
/// workspace and syncs sidebar selection); dropping a dragged tab on it routes
/// through ``SidebarTabDropDelegate``. It renders a top drop indicator and hosts
/// an app-supplied overlay (the Bonsplit new-workspace drop target, an
/// app-target `NSViewRepresentable` that cannot move into the package).
///
/// The view holds no store reference (snapshot-boundary rule): it takes an
/// immutable ``topDropIndicatorVisible`` snapshot, the tab drop delegate, the
/// injected ``accent`` color (the app supplies its `cmuxAccentColor()`), an
/// ``onActivateEmptyArea`` closure for the double-tap effect (which creates a
/// new workspace and syncs sidebar selection app-side), and an ``overlay``
/// builder for the app's drop overlay.
@MainActor
public struct SidebarEmptyArea<Overlay: View>: View {
    private let rowSpacing: CGFloat
    private let dragAutoScrollController: SidebarDragAutoScrollController
    // Value snapshot + closure bundles instead of an @Observable store
    // reference (snapshot-boundary rule).
    private let topDropIndicatorVisible: Bool
    private let tabDropDelegate: SidebarTabDropDelegate
    private let accent: Color
    private let onActivateEmptyArea: () -> Void
    private let overlay: () -> Overlay
    private let expandsVertically: Bool
    private let minimumHeight: CGFloat?

    /// Creates the sidebar empty-area drop/double-tap hit target.
    /// - Parameters:
    ///   - rowSpacing: The vertical spacing between rows, used to offset the
    ///     top drop indicator.
    ///   - dragAutoScrollController: Drives edge auto-scroll during the drag.
    ///   - topDropIndicatorVisible: Whether to render the top drop indicator.
    ///   - tabDropDelegate: The drop delegate handling dragged-tab drops.
    ///   - accent: The accent color used to fill the top drop indicator.
    ///   - expandsVertically: Whether the hit target fills available height.
    ///   - minimumHeight: The minimum height when not expanding vertically.
    ///   - onActivateEmptyArea: Invoked on a double-click of the empty area;
    ///     the app creates a new workspace, syncs sidebar selection state, and
    ///     sets the sidebar selection to its tabs lane.
    ///   - overlay: Builds the app-supplied overlay (the Bonsplit new-workspace
    ///     drop target) layered over the hit target.
    public init(
        rowSpacing: CGFloat,
        dragAutoScrollController: SidebarDragAutoScrollController,
        topDropIndicatorVisible: Bool,
        tabDropDelegate: SidebarTabDropDelegate,
        accent: Color,
        expandsVertically: Bool = true,
        minimumHeight: CGFloat? = nil,
        onActivateEmptyArea: @escaping () -> Void,
        @ViewBuilder overlay: @escaping () -> Overlay
    ) {
        self.rowSpacing = rowSpacing
        self.dragAutoScrollController = dragAutoScrollController
        self.topDropIndicatorVisible = topDropIndicatorVisible
        self.tabDropDelegate = tabDropDelegate
        self.accent = accent
        self.expandsVertically = expandsVertically
        self.minimumHeight = minimumHeight
        self.onActivateEmptyArea = onActivateEmptyArea
        self.overlay = overlay
    }

    public var body: some View {
        hitTarget
            .onTapGesture(count: 2, perform: onActivateEmptyArea)
            .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: tabDropDelegate)
            .overlay {
                overlay()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .top) {
                if topDropIndicatorVisible {
                    Rectangle()
                        .fill(accent)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    @ViewBuilder
    private var hitTarget: some View {
        if expandsVertically {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        } else {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: minimumHeight ?? 0)
                .contentShape(Rectangle())
        }
    }
}
