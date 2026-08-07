import AppKit
import SwiftUI

/// A native parent-and-children sidebar region whose leading column can be
/// resized independently from the host-owned trailing edge.
///
/// CMUX uses this primitive for its execution-context and workspace columns.
/// Sidebar extensions can use the same container so custom navigation layers
/// inherit the native divider, cursor, and sizing behavior.
@MainActor
public struct CmuxSidebarColumns<Leading: View, Trailing: View>: View {
    @Binding private var leadingWidth: CGFloat
    private let trailingWidth: CGFloat
    private let minimumLeadingWidth: CGFloat
    private let maximumLeadingWidth: CGFloat
    private let dividerAccessibilityIdentifier: String
    private let childColumn: CmuxSidebarChildColumn
    private let onResizeBegan: @MainActor () -> Void
    private let onResizeEnded: @MainActor () -> Void
    private let leading: Leading
    private let trailing: Trailing

    @State private var dragStartWidth: CGFloat?

    /// Creates a native column region whose selected parent owns the next
    /// column's route.
    ///
    /// The child builder receives the route descriptor from the selected
    /// parent. Switching routes gives the child subtree the route's stable
    /// identity. A child can nest another `CmuxSidebarColumns` to continue the
    /// hierarchy without changing this container.
    public init(
        leadingWidth: Binding<CGFloat>,
        trailingWidth: CGFloat,
        childColumn: CmuxSidebarChildColumn,
        minimumLeadingWidth: CGFloat = 120,
        maximumLeadingWidth: CGFloat = 320,
        dividerAccessibilityIdentifier: String = "SidebarColumnResizer",
        onResizeBegan: @escaping @MainActor () -> Void = {},
        onResizeEnded: @escaping @MainActor () -> Void = {},
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder children: (CmuxSidebarChildColumn) -> Trailing
    ) {
        _leadingWidth = leadingWidth
        self.trailingWidth = trailingWidth
        self.minimumLeadingWidth = minimumLeadingWidth
        self.maximumLeadingWidth = maximumLeadingWidth
        self.dividerAccessibilityIdentifier = dividerAccessibilityIdentifier
        self.childColumn = childColumn
        self.onResizeBegan = onResizeBegan
        self.onResizeEnded = onResizeEnded
        self.leading = leading()
        self.trailing = children(childColumn)
    }

    public var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: resolvedLeadingWidth)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .trailing) {
                    divider
                        .offset(x: Self.dividerHitWidth / 2)
                        .zIndex(1)
                }

            trailing
                .id(childColumn.id)
                .frame(width: resolvedTrailingWidth)
                .frame(maxHeight: .infinity)
        }
        .frame(width: resolvedLeadingWidth + resolvedTrailingWidth)
        .onDisappear {
            finishResizeIfNeeded()
        }
    }

    private static var dividerHitWidth: CGFloat {
        10
    }

    private var resolvedLeadingWidth: CGFloat {
        Self.clampedWidth(
            leadingWidth,
            minimum: minimumLeadingWidth,
            maximum: maximumLeadingWidth
        )
    }

    private var resolvedTrailingWidth: CGFloat {
        guard trailingWidth.isFinite else { return 0 }
        return max(0, trailingWidth)
    }

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
        .accessibilityIdentifier(dividerAccessibilityIdentifier)
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
                    let startWidth = dragStartWidth ?? resolvedLeadingWidth
                    if dragStartWidth == nil {
                        dragStartWidth = startWidth
                        onResizeBegan()
                    }
                    leadingWidth = Self.clampedWidth(
                        startWidth + value.translation.width,
                        minimum: minimumLeadingWidth,
                        maximum: maximumLeadingWidth
                    )
                    NSCursor.resizeLeftRight.set()
                }
                .onEnded { _ in
                    finishResizeIfNeeded()
                }
        )
    }

    private func finishResizeIfNeeded() {
        guard dragStartWidth != nil else { return }
        dragStartWidth = nil
        onResizeEnded()
    }

    /// Clamps a column width while rejecting non-finite input.
    public nonisolated static func clampedWidth(
        _ candidate: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let resolvedMinimum = minimum.isFinite ? max(0, minimum) : 0
        let resolvedMaximum = maximum.isFinite
            ? max(resolvedMinimum, maximum)
            : resolvedMinimum
        guard candidate.isFinite else { return resolvedMinimum }
        return min(max(candidate, resolvedMinimum), resolvedMaximum)
    }
}
