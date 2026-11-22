import AppKit
import os

/// VoiceOver and automation element for one layer-drawn tab or chip. The
/// strip view is its parent and keeps `accessibilityFrameInParentSpace`
/// in sync with the layer frame.
/// AppKit calls accessibility on the main thread, but `NSAccessibilityElement`
/// is not main-actor isolated, so the callbacks check the thread and then
/// enter the main actor with `assumeIsolated`.
nonisolated final class TabAccessibilityElement: NSAccessibilityElement, @unchecked Sendable {
    nonisolated(unsafe) var onPress: (@MainActor () -> Void)?
    nonisolated(unsafe) var onClose: (@MainActor () -> Void)?
    /// VoiceOver moved its focus onto (true) or off (false) this element.
    nonisolated(unsafe) var onFocus: (@MainActor (Bool) -> Void)?

    override init() {
        super.init()
        setAccessibilityRole(.radioButton)
        setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXTabButton"))
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress, Self.onMain("press") else { return false }
        MainActor.assumeIsolated { onPress() } // main-proof: guarded by Self.onMain (Thread.isMainThread) above
        return true
    }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        super.setAccessibilityFocused(accessibilityFocused)
        guard let onFocus, Self.onMain("focus") else { return }
        MainActor.assumeIsolated { onFocus(accessibilityFocused) } // main-proof: guarded by Self.onMain (Thread.isMainThread) above
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let onClose, Self.onMain("custom actions") else { return nil }
        let name = MainActor.assumeIsolated { Strings.axClose } // main-proof: guarded by Self.onMain (Thread.isMainThread) above
        return [NSAccessibilityCustomAction(name: name) {
            guard Self.onMain("close") else { return false }
            MainActor.assumeIsolated { onClose() } // main-proof: guarded by Self.onMain (Thread.isMainThread) above
            return true
        }]
    }

    /// Faults from accessibility callbacks that arrive off the main thread.
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "tabs.accessibility")

    /// AppKit calls accessibility on the main thread; anywhere else the
    /// callback refuses (a fault, no handler runs) instead of trapping.
    private static func onMain(_ callback: String) -> Bool {
        guard Thread.isMainThread else {
            logger.fault("tab accessibility \(callback, privacy: .public) off the main thread; refused")
            return false
        }
        return true
    }
}

// VoiceOver label and selected value of a tab.
extension TabCell {
    func updateAccessibility() {
        var parts = [displayTitle]
        if item.isPinned { parts.append(Strings.axPinned) }
        if item.indicator.isWorking { parts.append(Strings.axWorking) } else if item.isBusy { parts.append(Strings.axBusy) }
        if item.isDormant { parts.append(Strings.axHibernated) }
        if let machine = item.machineBadge { parts.append(Strings.axOnMachine(machine)) }
        if let profile = item.profileBadge { parts.append(Strings.browserProfile(profile.name)) }
        if let theme = item.themeBadge { parts.append(Strings.axTheme(theme.name)) }
        switch item.status {
        case .needsInput: parts.append(Strings.axNeedsInput)
        case .success: parts.append(Strings.axSuccess)
        case .failure: parts.append(Strings.axFailure)
        case .none: if item.isUnread { parts.append(Strings.axUnread) }
        }
        accessibility.setAccessibilityLabel(parts.joined(separator: ", "))
        accessibility.setAccessibilityValue(isSelected ? 1 : 0)
        accessibility.setAccessibilityHelp([item.machineBadgeHelp, item.subtitle].compactMap(\.self).joined(separator: ", "))
    }
}
