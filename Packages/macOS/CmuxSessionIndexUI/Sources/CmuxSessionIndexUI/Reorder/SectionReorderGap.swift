public import AppKit
public import CmuxSessionIndex
public import SwiftUI

/// Closure action bundle the host hands to ``SectionReorderGap`` for section
/// drag-reorder.
///
/// The gap and its ``SectionGapDropDelegate`` never hold a reference to the
/// session-index store or the drag coordinator; the host owns both and exposes
/// only these `@MainActor` closures. That keeps the drop-gap below the lazy-list
/// boundary free of any `@Observable`/`ObservableObject` reference, so an
/// unrelated store change cannot invalidate every gap and thrash the layout
/// cache (the snapshot-boundary rule).
///
/// All three closures speak ``SectionKey`` (`CmuxSessionIndex.SectionKey`), the
/// only domain type the reorder gap touches.
public struct SectionGapActions {
    /// Returns the section key currently being dragged, or `nil` when no drag is
    /// in flight. Read during drop validation.
    public let currentDraggedKey: @MainActor () -> SectionKey?
    /// Moves the first section before the second; a `nil` target appends to the
    /// end of the persisted order.
    public let moveSection: @MainActor (SectionKey, SectionKey?) -> Void
    /// Clears the in-flight dragged key once a drop has been handled.
    public let clearDraggedKey: @MainActor () -> Void

    /// Creates the reorder-gap action bundle.
    public init(
        currentDraggedKey: @escaping @MainActor () -> SectionKey?,
        moveSection: @escaping @MainActor (SectionKey, SectionKey?) -> Void,
        clearDraggedKey: @escaping @MainActor () -> Void
    ) {
        self.currentDraggedKey = currentDraggedKey
        self.moveSection = moveSection
        self.clearDraggedKey = clearDraggedKey
    }
}

/// A thin drop target between section headers that reorders sections by drag.
///
/// Pure SwiftUI: it renders a 4pt-tall clear strip that draws an accent capsule
/// while a valid section is hovering over it, and forwards the drop to the host
/// through ``SectionGapActions``. It owns only its view-local `isDropTarget`
/// flag and consumes ``SectionKey`` plus the closure actions, never the store.
public struct SectionReorderGap: View, Equatable {
    /// Section the dragged item should land BEFORE if dropped here. `nil` for
    /// the trailing gap (drop appends to the end of persisted order).
    private let beforeKey: SectionKey?
    /// Precomputed in the parent from the single draggedKey snapshot. Keeps
    /// the gap from reading drag state itself.
    private let isValidDrop: Bool
    /// Closure bundle — the gap never sees the session-index store or the drag
    /// coordinator directly, so it cannot observe them.
    private let actions: SectionGapActions
    @State private var isDropTarget: Bool = false

    /// Creates a section reorder drop-gap.
    public init(beforeKey: SectionKey?, isValidDrop: Bool, actions: SectionGapActions) {
        self.beforeKey = beforeKey
        self.isValidDrop = isValidDrop
        self.actions = actions
    }

    public static func == (lhs: SectionReorderGap, rhs: SectionReorderGap) -> Bool {
        lhs.beforeKey == rhs.beforeKey && lhs.isValidDrop == rhs.isValidDrop
    }

    public var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 4)
            .overlay(alignment: .center) {
                if isDropTarget && isValidDrop {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .padding(.horizontal, 10)
                }
            }
            .onDrop(
                of: [.text],
                delegate: SectionGapDropDelegate(
                    beforeKey: beforeKey,
                    actions: actions,
                    isDropTarget: $isDropTarget
                )
            )
    }
}

/// `DropDelegate` backing ``SectionReorderGap``.
///
/// Validates that the in-flight section is not being dropped onto its own gap,
/// reads the dragged ``SectionKey`` from the text payload of the
/// `NSItemProvider`, and forwards the move to the host through
/// ``SectionGapActions``. Co-located with the view it serves.
private struct SectionGapDropDelegate: DropDelegate {
    let beforeKey: SectionKey?
    let actions: SectionGapActions
    @Binding var isDropTarget: Bool

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.text]) else { return false }
        guard let dragged = actions.currentDraggedKey() else { return true }
        return dragged != beforeKey
    }

    func dropEntered(info: DropInfo) { isDropTarget = true }
    func dropExited(info: DropInfo) { isDropTarget = false }

    func performDrop(info: DropInfo) -> Bool {
        isDropTarget = false
        guard let provider = info.itemProviders(for: [.text]).first else {
            actions.clearDraggedKey()
            return false
        }
        let beforeKey = self.beforeKey
        let actions = self.actions
        provider.loadObject(ofClass: NSString.self) { object, _ in
            DispatchQueue.main.async {
                defer { actions.clearDraggedKey() }
                guard let raw = object as? String else { return }
                let key = SectionKey(raw: raw)
                actions.moveSection(key, beforeKey)
            }
        }
        return true
    }
}
