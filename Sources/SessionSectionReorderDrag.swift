import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Callback bundle for `SectionReorderGap` / `SectionGapDropDelegate`.
struct SectionGapActions {
    let currentDraggedKey: @MainActor () -> SectionKey?
    let moveSection: @MainActor (SectionKey, SectionKey?) -> Void
    let clearDraggedKey: @MainActor () -> Void
}

struct SectionReorderGap: View, Equatable {
    /// Section the dragged item should land BEFORE if dropped here. `nil` for
    /// the trailing gap (drop appends to the end of persisted order).
    let beforeKey: SectionKey?
    /// Precomputed in the parent from the single draggedKey snapshot. Keeps
    /// the gap from reading drag state itself.
    let isValidDrop: Bool
    /// Closure bundle — the gap never sees `SessionIndexStore` or
    /// `SessionDragCoordinator` directly, so it cannot `@ObservedObject` them.
    let actions: SectionGapActions
    @State private var isDropTarget: Bool = false

    static func == (lhs: SectionReorderGap, rhs: SectionReorderGap) -> Bool {
        lhs.beforeKey == rhs.beforeKey && lhs.isValidDrop == rhs.isValidDrop
    }

    var body: some View {
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
