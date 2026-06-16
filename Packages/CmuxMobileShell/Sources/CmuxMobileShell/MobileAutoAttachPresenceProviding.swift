public import Foundation

/// An online/offline signal for registry-driven auto-attach target selection.
///
/// Optional seam: when no presence provider is wired (the presence service is
/// not merged yet, #5792), auto-attach degrades to most-recently-seen selection,
/// which is correct for the dominant single-Mac team. Once the presence client
/// lands, an adapter conforming to this protocol lets auto-attach prefer the live
/// Mac and treat multiple live Macs as ambiguous (fall through to manual pair)
/// rather than guessing on recency.
public protocol MobileAutoAttachPresenceProviding: Sendable {
    /// The device ids the presence service currently reports as online, scoped to
    /// the signed-in user's team. Best-effort: a `nil` snapshot means "no
    /// presence signal right now," so selection falls back to recency.
    func onlineDeviceIDs() async -> Set<String>?
}
