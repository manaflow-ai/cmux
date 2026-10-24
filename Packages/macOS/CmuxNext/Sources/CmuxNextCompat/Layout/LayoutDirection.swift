/// Direction for keyboard focus movement, pane resize and neighbor lookup.
///
/// A pure value, so it is core: CmuxNextLayout (ui) moves focus with it and
/// CmuxNextDaemonService (service) names it in refusal reasons without
/// depending on the Layout target. CmuxNextLayout keeps the same spelling
/// through a typealias.
public nonisolated enum LayoutDirection: Hashable, Sendable, CaseIterable {
    case left, right, up, down
}
