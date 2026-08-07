import Foundation

/// How the sidebar's last-interaction label
/// (`sidebar.showLastInteractionInsteadOfPath`) renders the timestamp.
/// `relative` is the terse "now/12m/3h/2d" bucket label that ticks forward
/// on its own; `absolute` is a static short time-of-day with seconds, so two
/// prompts submitted within the same minute can still be ordered without a
/// hover.
public enum SidebarLastInteractionTimestampStyle: String, CaseIterable, Sendable, SettingCodable {
    case relative
    case absolute
}
