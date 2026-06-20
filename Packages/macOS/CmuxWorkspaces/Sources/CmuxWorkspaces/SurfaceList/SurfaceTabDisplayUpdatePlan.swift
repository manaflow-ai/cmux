public import Foundation
public import Bonsplit

/// The minimal set of `BonsplitController.updateTab(_:…)` deltas a panel's
/// display-state change should apply to its surface tab, plus whether any delta
/// landed at all.
///
/// Every panel-subscription installer in the legacy `Workspace` god object
/// (`installBrowserPanelSubscription`, `installMarkdownPanelSubscription`,
/// `installFilePreviewPanelSubscription`, `installAgentSessionPanelSubscription`)
/// ran the same diff arithmetic before writing to bonsplit: compare each desired
/// display value against the existing ``Bonsplit/Tab`` field, keep only the ones
/// that actually changed, bail when none did, and otherwise call `updateTab`
/// with exactly those deltas plus the always-passed `hasCustomTitle`. That diff
/// is pure value logic over a ``Bonsplit/Tab`` snapshot, so it lives here as a
/// computed plan the app-side installers build and apply, instead of being
/// re-spelled four times.
///
/// The installers themselves stay app-side: they own the Combine `$`-publisher
/// subscriptions, the app-target panel classes, the `panelSubscriptions`
/// storage, and the surface-id-to-panel-id resolution. Only the diff-and-apply
/// shape is shared here. The optional-of-optional fields (`icon`,
/// `iconImageData`) mirror `updateTab`'s `String??` / `Data??` parameters
/// exactly: `nil` means "no change", `.some(value)` means "set to value"
/// (`value` itself may be `nil`).
///
/// `hasCustomTitle` is intentionally always carried (never elided), because the
/// legacy bodies passed it on every `updateTab` call regardless of whether the
/// title itself changed; preserving that keeps the bonsplit write byte-identical.
public struct SurfaceTabDisplayUpdatePlan: Equatable, Sendable {
    /// The new title to apply, or `nil` to leave the tab's title unchanged.
    public var title: String?

    /// The new icon to apply (`String??`: outer `nil` = no change, inner `nil` =
    /// clear the icon), matching `updateTab`'s `icon` parameter.
    public var icon: String??

    /// The new icon image data to apply (`Data??`: outer `nil` = no change,
    /// inner `nil` = clear the image), matching `updateTab`'s `iconImageData`
    /// parameter.
    public var iconImageData: Data??

    /// The custom-title flag, always carried (the legacy installers passed it on
    /// every `updateTab` call).
    public var hasCustomTitle: Bool

    /// The new dirty flag, or `nil` to leave it unchanged.
    public var isDirty: Bool?

    /// The new loading flag, or `nil` to leave it unchanged.
    public var isLoading: Bool?

    /// The new audio-muted flag, or `nil` to leave it unchanged.
    public var isAudioMuted: Bool?

    /// Whether this plan would write nothing to the tab. True exactly when no
    /// display field differs from the existing tab; installers skip the
    /// `updateTab` call in that case, matching the legacy `guard … else { return }`.
    public var isEmpty: Bool {
        title == nil
            && icon == nil
            && iconImageData == nil
            && isDirty == nil
            && isLoading == nil
            && isAudioMuted == nil
    }

    /// Builds an explicit plan. Prefer ``init(existing:resolvedTitle:hasCustomTitle:icon:iconImageData:isDirty:isLoading:isAudioMuted:)``,
    /// which computes the deltas from an existing tab.
    public init(
        title: String? = nil,
        icon: String?? = nil,
        iconImageData: Data?? = nil,
        hasCustomTitle: Bool,
        isDirty: Bool? = nil,
        isLoading: Bool? = nil,
        isAudioMuted: Bool? = nil
    ) {
        self.title = title
        self.icon = icon
        self.iconImageData = iconImageData
        self.hasCustomTitle = hasCustomTitle
        self.isDirty = isDirty
        self.isLoading = isLoading
        self.isAudioMuted = isAudioMuted
    }

    /// Computes the minimal deltas needed to bring `existing` to the desired
    /// display values, leaving any unspecified field unchanged.
    ///
    /// Each delta is included only when it differs from the corresponding field
    /// of `existing`, reproducing the legacy
    /// `let xUpdate = existing.x == newX ? nil : newX` arithmetic one-for-one.
    /// `hasCustomTitle` is always recorded. Passing `nil` for `icon`,
    /// `iconImageData`, `isDirty`, `isLoading`, or `isAudioMuted` means the
    /// installer does not manage that field (e.g. the markdown installer never
    /// touches the icon), so the plan never proposes a change for it.
    ///
    /// - Parameters:
    ///   - existing: The current bonsplit tab snapshot.
    ///   - resolvedTitle: The fully-resolved title the installer computed, or
    ///     `nil` when the installer does not manage the title.
    ///   - hasCustomTitle: The custom-title flag to carry on the write.
    ///   - icon: The desired icon (`.some` to manage it, `nil` to leave it
    ///     unmanaged). The contained `String?` follows `updateTab` semantics.
    ///   - iconImageData: The desired icon image data, same convention as `icon`.
    ///   - isDirty: The desired dirty flag, or `nil` when unmanaged.
    ///   - isLoading: The desired loading flag, or `nil` when unmanaged.
    ///   - isAudioMuted: The desired audio-muted flag, or `nil` when unmanaged.
    public init(
        existing: Bonsplit.Tab,
        resolvedTitle: String?,
        hasCustomTitle: Bool,
        icon: String?? = nil,
        iconImageData: Data?? = nil,
        isDirty: Bool? = nil,
        isLoading: Bool? = nil,
        isAudioMuted: Bool? = nil
    ) {
        self.title = resolvedTitle.flatMap { existing.title == $0 ? nil : $0 }
        if let icon {
            self.icon = existing.icon == icon ? nil : .some(icon)
        } else {
            self.icon = nil
        }
        if let iconImageData {
            self.iconImageData = existing.iconImageData == iconImageData ? nil : .some(iconImageData)
        } else {
            self.iconImageData = nil
        }
        self.hasCustomTitle = hasCustomTitle
        self.isDirty = isDirty.flatMap { existing.isDirty == $0 ? nil : $0 }
        self.isLoading = isLoading.flatMap { existing.isLoading == $0 ? nil : $0 }
        self.isAudioMuted = isAudioMuted.flatMap { existing.isAudioMuted == $0 ? nil : $0 }
    }

    /// Applies this plan to `controller`'s tab `tabId` via a single
    /// `updateTab(_:…)` call carrying exactly the recorded deltas, mirroring the
    /// legacy installer's terminal `bonsplitController.updateTab(...)` write.
    ///
    /// No-ops when ``isEmpty`` is true so callers can apply unconditionally; the
    /// legacy bodies guarded the call themselves, and skipping an all-`nil`
    /// `updateTab` is behavior-identical (bonsplit applies no field for `nil`
    /// arguments).
    @MainActor
    public func apply(to controller: BonsplitController, tabId: TabID) {
        guard !isEmpty else { return }
        controller.updateTab(
            tabId,
            title: title,
            icon: icon,
            iconImageData: iconImageData,
            hasCustomTitle: hasCustomTitle,
            isDirty: isDirty,
            isLoading: isLoading,
            isAudioMuted: isAudioMuted
        )
    }
}
