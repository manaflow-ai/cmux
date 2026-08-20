import AppKit
import SwiftUI

/// Finder-style two-column sidebar region: machines on the left, the
/// selected machine's workspaces next. Column widths arrive as resolved
/// values (regular width or icon rail) so this container stays a dumb
/// geometry shell; the snap policy lives with the caller.
///
/// The internal divider reports raw pointer-derived widths through
/// `onLeadingDrag`, letting the caller resolve snap-to-icons and write the
/// layout model. Double-clicking the divider toggles the machines column
/// between regular and icon presentation.
struct SidebarColumnsContainer<Leading: View, Trailing: View>: View {
    let leadingWidth: CGFloat
    let trailingWidth: CGFloat
    /// Stable identity for the trailing subtree (the selected machine's
    /// route) so switching machines resets scroll and selection state.
    let trailingIdentity: String
    let onLeadingDrag: @MainActor (CGFloat) -> Void
    let onLeadingDragEnded: @MainActor () -> Void
    let onToggleLeadingMode: @MainActor () -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    @State private var dragStartWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            leading()
                .frame(width: max(0, leadingWidth))
                .frame(maxHeight: .infinity)
                .clipped()
                .overlay(alignment: .trailing) {
                    divider
                        .offset(x: Self.dividerHitWidth / 2)
                        .zIndex(1)
                }

            trailing()
                .id(trailingIdentity)
                .frame(width: max(0, trailingWidth))
                .frame(maxHeight: .infinity)
                .clipped()
        }
        .frame(width: max(0, leadingWidth) + max(0, trailingWidth))
        .onDisappear {
            finishDragIfNeeded()
        }
    }

    private static var dividerHitWidth: CGFloat { 10 }

    private var divider: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.72))
                .frame(width: 1)

            Color.clear
                .frame(width: Self.dividerHitWidth)
                .contentShape(Rectangle())
        }
        .frame(width: Self.dividerHitWidth)
        .accessibilityIdentifier("SidebarColumnResizer")
        .onHover { hovering in
            if hovering || dragStartWidth != nil {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let startWidth = dragStartWidth ?? leadingWidth
                    if dragStartWidth == nil {
                        dragStartWidth = startWidth
                    }
                    onLeadingDrag(startWidth + value.translation.width)
                    NSCursor.resizeLeftRight.set()
                }
                .onEnded { _ in
                    finishDragIfNeeded()
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onToggleLeadingMode()
            }
        )
    }

    private func finishDragIfNeeded() {
        guard dragStartWidth != nil else { return }
        dragStartWidth = nil
        onLeadingDragEnded()
    }
}
