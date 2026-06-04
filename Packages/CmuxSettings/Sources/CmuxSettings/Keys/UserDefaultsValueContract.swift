import Foundation

extension AnySettingKey {
    /// A comparable fingerprint of a `UserDefaults`-backed entry's value
    /// contract: the `Value` type it decodes as and the default it falls back
    /// to (rendered in a canonical, order-independent form).
    ///
    /// The catalog intentionally surfaces some storage keys under two ids so
    /// that two settings UIs stay in sync on one stored value — the
    /// `automation.*` ↔ `integrations.*` reorg and the `sidebar.*` ↔
    /// `workspaceColors.*` pair. That aliasing is safe *only* while both
    /// entries agree on this contract: if they disagreed on ``valueTypeName``
    /// or ``defaultStorageRepresentation``, reading the shared key through one
    /// surface would mis-decode or return a different fallback than the other.
    /// ``AnySettingKey`` erases the concrete `Value`, so the contract is
    /// captured at construction to make that agreement checkable from the
    /// type-erased catalog list.
    ///
    /// ```swift
    /// let a = AnySettingKey(DefaultsKey<Bool>(
    ///     id: "x.a", defaultValue: false, userDefaultsKey: "flag"))
    /// let b = AnySettingKey(DefaultsKey<Bool>(
    ///     id: "x.b", defaultValue: false, userDefaultsKey: "flag"))
    /// // Two ids aliasing one storage key agree on the contract:
    /// a.userDefaultsValueContract == b.userDefaultsValueContract  // true
    /// ```
    ///
    /// - SeeAlso: ``AnySettingKey/userDefaultsValueContract``
    public struct UserDefaultsValueContract: Sendable, Hashable {
        /// The fully-qualified name of the entry's `Value` type — for example
        /// `"Swift.Bool"` or `"CmuxSettings.WorkspaceIndicatorStyle"`.
        public let valueTypeName: String

        /// The entry's default value rendered in a canonical, order-independent
        /// form of its `UserDefaults` encoding, so two equal defaults always
        /// compare equal regardless of dictionary key-enumeration order.
        public let defaultStorageRepresentation: String
    }
}
