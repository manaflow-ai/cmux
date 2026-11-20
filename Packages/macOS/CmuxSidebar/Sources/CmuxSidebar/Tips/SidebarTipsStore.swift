public import Foundation
public import SwiftUI

/// Owns persisted tip progress and observes changes made by other windows.
///
/// Inject an isolated `UserDefaults(suiteName:)` to exercise storage without
/// launching the app. Opening and paging both read the latest persisted history
/// before writing, so an older view snapshot cannot discard another window's tips.
@MainActor
public struct SidebarTipsStore: DynamicProperty {
    private static let currentTipIDKey = "sidebarTips.currentTipID"
    private static let seenTipIDsKey = "sidebarTips.seenTipIDs"
    private static let lastOpenedDayKey = "sidebarTips.lastOpenedDay"
    private static let lastOpenedAtKey = "sidebarTips.lastOpenedAt"
    // Preserve the original opt-out key across the change to automatic reminders.
    private static let automaticTipsDisabledKey = "sidebarTips.hidden"

    private let defaults: UserDefaults
    private let schedule = SidebarTipsSchedule()
    @AppStorage private var currentTipID: String
    @AppStorage private var seenTipIDs: String
    @AppStorage private var lastOpenedDay: String
    @AppStorage private var lastOpenedAt: Double
    /// Whether automatic reminders are disabled; manual viewing stays available.
    @AppStorage public var automaticTipsDisabled: Bool

    /// Creates an observable store backed by the supplied preferences domain.
    /// - Parameter defaults: The shared app domain or an isolated test suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        _currentTipID = AppStorage(wrappedValue: "", Self.currentTipIDKey, store: defaults)
        _seenTipIDs = AppStorage(wrappedValue: "", Self.seenTipIDsKey, store: defaults)
        _lastOpenedDay = AppStorage(wrappedValue: "", Self.lastOpenedDayKey, store: defaults)
        _lastOpenedAt = AppStorage(wrappedValue: 0, Self.lastOpenedAtKey, store: defaults)
        _automaticTipsDisabled = AppStorage(wrappedValue: false, Self.automaticTipsDisabledKey, store: defaults)
    }

    /// The observed progress snapshot for rendering and reminder eligibility.
    public var progress: SidebarTipsProgress {
        decode(
            currentTipID: currentTipID, seenTipIDs: seenTipIDs, lastOpenedDay: lastOpenedDay,
            automaticTipsDisabled: automaticTipsDisabled, lastOpenedAt: lastOpenedAt
        )
    }

    /// Reads current persisted progress, including writes from another view.
    public func load() -> SidebarTipsProgress {
        decode(
            currentTipID: defaults.string(forKey: Self.currentTipIDKey) ?? "",
            seenTipIDs: defaults.string(forKey: Self.seenTipIDsKey) ?? "",
            lastOpenedDay: defaults.string(forKey: Self.lastOpenedDayKey) ?? "",
            automaticTipsDisabled: defaults.bool(forKey: Self.automaticTipsDisabledKey),
            lastOpenedAt: defaults.double(forKey: Self.lastOpenedAtKey)
        )
    }

    /// Records a presentation and its shared daily allowance.
    /// - Parameters:
    ///   - tipIDs: Currently applicable tips in display order.
    ///   - now: The presentation time, supplied by the caller.
    ///   - automaticTipID: The new tip or weekly refresher chosen automatically.
    public func open(tipIDs: [String], now: Date, automaticTipID: String? = nil) {
        let next = schedule.opened(load(), tipIDs: tipIDs, now: now, preferredTipID: automaticTipID)
        currentTipID = next.currentTipID ?? ""
        seenTipIDs = next.seenTipIDs.sorted().joined(separator: ",")
        lastOpenedDay = next.lastOpenedDay ?? ""
        lastOpenedAt = next.lastOpenedAt?.timeIntervalSince1970 ?? 0
    }

    /// Records paging without changing the reminder timestamp or opt-out.
    /// - Parameter tipID: The tip the user selected.
    public func select(_ tipID: String) {
        let next = schedule.selected(load(), tipID: tipID)
        currentTipID = next.currentTipID ?? ""
        seenTipIDs = next.seenTipIDs.sorted().joined(separator: ",")
    }

    private func decode(
        currentTipID: String, seenTipIDs: String, lastOpenedDay: String,
        automaticTipsDisabled: Bool, lastOpenedAt: Double
    ) -> SidebarTipsProgress {
        SidebarTipsProgress(
            currentTipID: currentTipID.isEmpty ? nil : currentTipID,
            seenTipIDs: Set(seenTipIDs.split(separator: ",").map(String.init)),
            lastOpenedDay: lastOpenedDay.isEmpty ? nil : lastOpenedDay,
            automaticTipsDisabled: automaticTipsDisabled,
            lastOpenedAt: lastOpenedAt > 0 ? Date(timeIntervalSince1970: lastOpenedAt) : nil
        )
    }
}
