import SwiftUI

/// Carries the mounted inline preview's action descriptor to an ancestor toolbar.
public struct ChatArtifactInlineActionsPreferenceKey: PreferenceKey {
    /// No toolbar actions are available when no loaded inline preview reports them.
    public static let defaultValue: ChatArtifactInlineActionDescriptor? = nil

    /// Keeps the mounted preview descriptor while ignoring empty sibling values.
    public static func reduce(
        value: inout ChatArtifactInlineActionDescriptor?,
        nextValue: () -> ChatArtifactInlineActionDescriptor?
    ) {
        value = nextValue() ?? value
    }
}
