import AppKit
import Foundation

extension RightSidebarMode {
    static func from(cliArgument rawValue: String) -> RightSidebarMode? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "files":
            return .files
        case "find":
            return .find
        case "vault", "sessions":
            return .sessions
        case "feed":
            return .feed
        case "dock":
            return .dock
        case "cloud", "machines", "vms":
            return .machines
        default:
            return nil
        }
    }

    static func availableModes(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        availableModes(
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults),
            machinesEnabled: CloudMachinesFeature.offMainIsEnabled(defaults: defaults)
        )
    }

    static func availableModes(feedEnabled: Bool, dockEnabled: Bool, machinesEnabled: Bool) -> [RightSidebarMode] {
        allCases.filter {
            $0 != .customSidebar && $0.isAvailable(
                feedEnabled: feedEnabled,
                dockEnabled: dockEnabled,
                machinesEnabled: machinesEnabled
            )
        }
    }

    func isAvailable(defaults: UserDefaults = .standard) -> Bool {
        isAvailable(
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults),
            machinesEnabled: CloudMachinesFeature.offMainIsEnabled(defaults: defaults)
        )
    }

    /// The tabs the mode bar actually shows: feature-available modes in the
    /// user's configured order, minus the ones the user hid. This list also
    /// defines the positional `ctrl+1…9` digit-shortcut defaults, so the Nth
    /// visible tab always answers ctrl+N unless the user rebound it.
    nonisolated static func visibleModes(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        let hidden = RightSidebarTabPreferences.hiddenModes(defaults: defaults)
        let visible = RightSidebarTabPreferences.orderedModes(defaults: defaults)
            .filter { $0.isAvailable(defaults: defaults) && !hidden.contains($0) }
        guard visible.isEmpty else { return visible }

        // A feature gate can remove the last available tab after the user has
        // hidden every other tab. Restore the first available tab explicitly,
        // rather than treating all hidden tabs as visible again.
        guard let fallback = availableModes(defaults: defaults).first else { return [] }
        _ = RightSidebarTabPreferences.setHidden(false, mode: fallback, defaults: defaults)
        return RightSidebarTabPreferences.orderedModes(defaults: defaults)
            .filter { $0.isAvailable(defaults: defaults) && !RightSidebarTabPreferences.isHidden($0, defaults: defaults) }
    }

    /// 1-based `ctrl+digit` position of `mode` among the visible tabs, or nil
    /// when the mode is hidden, unavailable, or past position 9. Single source
    /// for the app's positional shortcut defaults and the CmuxSettings
    /// default-stroke override.
    nonisolated static func positionalDigit(
        for mode: RightSidebarMode,
        defaults: UserDefaults = .standard
    ) -> Int? {
        let visible = visibleModes(defaults: defaults)
        guard let index = visible.firstIndex(of: mode), index < 9 else { return nil }
        return index + 1
    }

    func isAvailable(feedEnabled: Bool, dockEnabled: Bool, machinesEnabled: Bool) -> Bool {
        switch self {
        case .files, .find, .sessions:
            return true
        case .feed:
            return feedEnabled
        case .dock:
            return dockEnabled
        case .machines:
            return machinesEnabled
        case .customSidebar:
            return false
        }
    }
}

enum RightSidebarKeyboardNavigation {
    enum DisclosureAction {
        case collapse
        case expand
    }

    static func moveDelta(for event: NSEvent) -> Int? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommandOrOption = !flags.intersection([.command, .option]).isEmpty
        if flags.contains(.control), !hasCommandOrOption {
            switch event.keyCode {
            case 45: return 1   // Ctrl+N
            case 35: return -1  // Ctrl+P
            default: break
            }
        }

        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }
        switch event.keyCode {
        case 38, 125: return 1   // J or Down
        case 40, 126: return -1  // K or Up
        default: return nil
        }
    }

    static func disclosureAction(for event: NSEvent) -> DisclosureAction? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }
        switch event.keyCode {
        case 4: return .collapse  // H
        case 37: return .expand   // L
        case 123: return .collapse  // Left
        case 124: return .expand   // Right
        default: return nil
        }
    }

    static func isPlainSlash(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        return event.keyCode == 44
    }

    static func isPlainPrintableText(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        guard let text = event.charactersIgnoringModifiers, !text.isEmpty else {
            return false
        }
        return text.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }
}
