/// Direction for keyboard focus movement, pane resize and neighbor lookup.
///
/// A pure value, so it is core: CmuxNextLayout (ui) moves focus with it and
/// CmuxNextDaemonService (service) names it in refusal reasons without
/// depending on the Layout target. CmuxNextLayout spells it `LayoutDirection`
/// through a typealias. The core name differs from `SwiftUI.LayoutDirection`
/// on purpose: many SwiftUI files import CmuxNextCompat, and a second
/// top-level `LayoutDirection` there would make the bare name ambiguous.
public nonisolated enum FocusDirection: Hashable, Sendable, CaseIterable {
    case left, right, up, down
}
