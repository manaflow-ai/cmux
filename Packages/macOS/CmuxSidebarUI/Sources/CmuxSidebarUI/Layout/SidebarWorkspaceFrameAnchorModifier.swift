public import SwiftUI

/// Publishes a workspace row's bounds anchor into
/// ``SidebarWorkspaceRowFramePreferenceKey`` when frame collection is enabled.
///
/// The modifier is branchless on purpose: it always applies
/// `anchorPreference` and emits `[:]` when disabled, instead of an `if/else`.
/// An `if/else` would give `content` a distinct SwiftUI identity per state, so
/// toggling `isEnabled` at drag start/end recreated every visible row's subtree
/// (lost `@State`, fresh snapshot builds and relayout mid-drag). The frame
/// *reader* stays gated on the drag (see issue #5325), so an empty emit costs
/// nothing.
public struct SidebarWorkspaceFrameAnchorModifier: ViewModifier {
    private let id: UUID
    private let isEnabled: Bool

    /// - Parameters:
    ///   - id: The workspace row identifier the anchor is keyed by.
    ///   - isEnabled: When false the modifier emits an empty preference value
    ///     (still applying `anchorPreference` to preserve view identity).
    public init(id: UUID, isEnabled: Bool) {
        self.id = id
        self.isEnabled = isEnabled
    }

    public func body(content: Content) -> some View {
        content.anchorPreference(
            key: SidebarWorkspaceRowFramePreferenceKey.self,
            value: .bounds
        ) { anchor in
            isEnabled ? [id: anchor] : [:]
        }
    }
}

extension View {
    /// Publishes this view's bounds anchor into
    /// ``SidebarWorkspaceRowFramePreferenceKey`` keyed by `id` when `isEnabled`.
    public func sidebarWorkspaceFrameAnchor(id: UUID, isEnabled: Bool) -> some View {
        modifier(SidebarWorkspaceFrameAnchorModifier(id: id, isEnabled: isEnabled))
    }
}
