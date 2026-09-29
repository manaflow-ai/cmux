import AppKit

// VoiceOver and automation surface of a tab: label, selected value, press, close.
extension TabView {
    // MARK: - Accessibility

    func updateAccessibility() {
        var parts = [displayTitle]
        if item.isPinned { parts.append(Strings.axPinned) }
        if item.isBusy { parts.append(Strings.axBusy) }
        switch item.status {
        case .needsInput: parts.append(Strings.axNeedsInput)
        case .success: parts.append(Strings.axSuccess)
        case .failure: parts.append(Strings.axFailure)
        case .none: if item.isUnread { parts.append(Strings.axUnread) }
        }
        setAccessibilityLabel(parts.joined(separator: ", "))
        setAccessibilityValue(isSelected ? 1 : 0)
        setAccessibilityHelp(item.subtitle)
    }

    override func accessibilityPerformPress() -> Bool {
        onAccessibilityPress?()
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: Strings.axClose) { [weak self] in
            self?.onAccessibilityClose?()
            return true
        }]
    }
}
