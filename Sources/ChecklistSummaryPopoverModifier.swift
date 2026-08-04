import AppKit
import CmuxWorkspaces
import SwiftUI
/// Attaches the checklist popover to the section container (not just the
/// summary line — see the call site comment in ``SidebarWorkspaceChecklistSection/body``)
/// via `SidebarWorkspaceTodoPopoverHost` (a real NSPopover, not SwiftUI's
/// native `.popover()`): the checklist popover embeds a first-responder
/// TextField (the add/edit fields), and SwiftUI's native `.popover` does not
/// make its window key in cmux's focus-managed environment, so keystrokes
/// fall through to the terminal.
///
/// The anchor NSView is pinned to a fixed 1×1pt corner via `.overlay` rather
/// than spanning the whole section via `.background()`: an
/// NSViewRepresentable stacked as a `.background()` behind the full row was
/// found to suppress `.onHover` tracking for the item rows underneath it
/// (the hover-reveal delete "x" stopped appearing reliably). Shrinking its
/// footprint to a single corner point removes it from the row's
/// hit-testing/hover area while keeping one stable, always-present anchor
/// across the 0→1 item transition.
struct ChecklistSummaryPopoverModifier: ViewModifier {
    @Binding var isPresented: Bool
    let model: SidebarWorkspaceChecklistPopoverModel
    let actions: SidebarWorkspaceChecklistActions
    let onConsumeAddFieldActivation: () -> Void
    let onPopoverPresentedChange: @MainActor (Bool) -> Void

    func body(content: Content) -> some View {
        content
            // `.overlay(alignment: .topTrailing)` positions the anchor within
            // `content`'s own bounding box. For a zero-item workspace in
            // popover style, `content` (the section's VStack) renders no
            // children at all, so its natural size is 0×0 — topTrailing then
            // collapses to a single point at the VStack's own position, which
            // its leading-aligned parent places at the row's LEFT edge, not
            // the right edge. `maxWidth: .infinity` forces this container to
            // always claim the row's full width regardless of content, so
            // the anchor's trailing edge always matches the row's actual
            // right edge, whether or not any items exist yet.
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                SidebarWorkspaceTodoPopoverHost(
                    isPresented: $isPresented,
                    model: model,
                    minWidth: 320,
                    maxHeight: 520,
                    preferredEdge: .maxX,
                    // A context-menu/palette "Add Checklist Item…" bump is an
                    // explicit present request: it clears the host's external-
                    // dismissal latch so the popover can re-present even if
                    // the container's earlier `false` write hasn't landed yet.
                    presentationRequestToken: model.addFieldActivationToken
                ) { model, close in
                    SidebarWorkspaceChecklistPopover(
                        model: model,
                        actions: actions,
                        onConsumeAddFieldActivation: onConsumeAddFieldActivation,
                        onClose: {
                            close()
                            onPopoverPresentedChange(false)
                        }
                    )
                }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            }
    }
}
