import AppKit

/// VoiceOver and automation element for one layer-drawn tab or chip. The
/// strip view is its parent and keeps `accessibilityFrameInParentSpace`
/// in sync with the layer frame.
/// AppKit calls accessibility on the main thread, but `NSAccessibilityElement`
/// is not main-actor isolated, so the callbacks hop with `assumeIsolated`.
nonisolated final class TabAccessibilityElement: NSAccessibilityElement, @unchecked Sendable {
    nonisolated(unsafe) var onPress: (@MainActor () -> Void)?
    nonisolated(unsafe) var onClose: (@MainActor () -> Void)?

    override init() {
        super.init()
        setAccessibilityRole(.radioButton)
        setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXTabButton"))
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        MainActor.assumeIsolated { onPress() }
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let onClose else { return nil }
        let name = MainActor.assumeIsolated { Strings.axClose }
        return [NSAccessibilityCustomAction(name: name) {
            MainActor.assumeIsolated { onClose() }
            return true
        }]
    }
}

// VoiceOver label and selected value of a tab.
extension TabCell {
    func updateAccessibility() {
        var parts = [displayTitle]
        if item.isPinned { parts.append(Strings.axPinned) }
        if item.isBusy { parts.append(Strings.axBusy) }
        if item.isDormant { parts.append(Strings.axHibernated) }
        if let machine = item.machineBadge { parts.append(Strings.axOnMachine(machine)) }
        if let profile = item.profileBadge { parts.append(Strings.browserProfile(profile.name)) }
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
