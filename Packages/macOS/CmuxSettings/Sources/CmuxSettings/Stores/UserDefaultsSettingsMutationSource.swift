import Foundation

/// Identifies one caller-originated `UserDefaultsSettingsStore` mutation.
///
/// Consumers that optimistically update UI can attach a source to their store
/// write and ignore the matching observation echo without suppressing unrelated
/// external writes that happen to carry the same setting value.
public struct UserDefaultsSettingsMutationSource: Sendable, Hashable {
    fileprivate let rawValue: UUID

    /// Creates a unique mutation source for one logical write.
    public init() {
        self.rawValue = UUID()
    }
}
