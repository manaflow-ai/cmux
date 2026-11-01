import AppKit
import CmuxNextDesign
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
    /// The tab's badge actions and their handlers (`updateAccessibility`): "Mute tab" or "Unmute tab"
    /// while it shows a speaker, "Exit Zoom" while it shows a zoomed pane's indicator.
    nonisolated(unsafe) var badgeActions: [(name: String, run: @MainActor () -> Void)] = [] // crash-allow: set in updateAccessibility and read in accessibilityCustomActions, both on the main thread only (onMain guard), as onClose
    /// VoiceOver moved its focus onto (true) or off (false) this element.
    nonisolated(unsafe) var onFocus: (@MainActor (Bool) -> Void)?
    /// The tab's x as a pressable child: its press runs ``onClose``. It is a child while the tab
    /// can close and has room for it (the cell's layout gives it a nonzero frame). The x draws
    /// only on hover, but it is exposed while hidden too: an agent presses it with AXPress, and a
    /// pointer moving to its frame hovers the tab, which shows it there.
    let closeButton = TabCloseAccessibilityElement()

    override init() {
        super.init()
        setAccessibilityRole(.radioButton)
        setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXTabButton"))
        closeButton.setAccessibilityParent(self)
    }

    override func accessibilityChildren() -> [Any]? {
        onClose != nil && closeButton.accessibilityFrameInParentSpace() != .zero ? [closeButton] : nil
    }

    /// Closes the tab for its x's AXPress.
    func performClose() -> Bool {
        guard let onClose, Self.onMain("close") else { return false }
        MainActor.assumeIsolated { onClose() } // main-proof: guarded by Self.onMain (Thread.isMainThread) above
        return true
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
        guard Self.onMain("custom actions") else { return nil }
        var named = badgeActions
        if let onClose { named.append((MainActor.assumeIsolated { Strings.axClose }, onClose)) } // main-proof: guarded by Self.onMain (Thread.isMainThread) above
        guard !named.isEmpty else { return nil }
        return named.map { action in
            NSAccessibilityCustomAction(name: action.name) {
                guard Self.onMain("custom action") else { return false }
                MainActor.assumeIsolated { action.run() } // main-proof: guarded by Self.onMain (Thread.isMainThread) above
                return true
            }
        }
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
        if let presence = item.presence { parts.append(presence.summary) }
        if let audio = item.audio { parts.append(audio == .muted ? Strings.axMuted : Strings.axPlayingAudio) }
        if let theme = item.themeBadge { parts.append(Strings.axTheme(theme.name)) }
        if showsZoom { parts.append(Strings.axZoomed) }
        switch item.status {
        case .needsInput: parts.append(item.blockedKind.flatMap { StatusIndicatorState.waiting(kind: $0).shortLabel } ?? Strings.axNeedsInput)
        case .success: parts.append(Strings.axSuccess)
        case .failure: parts.append(Strings.axFailure)
        case .none: if item.isUnread { parts.append(Strings.axUnread) }
        }
        accessibility.setAccessibilityLabel(parts.joined(separator: ", "))
        accessibility.setAccessibilityIdentifier("cmux.tabs.tab.\(item.id.rawValue)")
        accessibility.closeButton.setAccessibilityLabel(Strings.axClose)
        accessibility.closeButton.setAccessibilityIdentifier("cmux.tabs.tab.\(item.id.rawValue).close")
        let audioAction = item.audio.flatMap { audio in
            accessibilityToggleAudio.map { (name: audio == .muted ? Strings.unmuteTab : Strings.muteTab, run: $0) }
        }
        let zoomAction = showsZoom ? accessibilityToggleZoom.map { (name: Strings.exitZoom, run: $0) } : nil
        accessibility.badgeActions = [audioAction, zoomAction].compactMap(\.self)
        accessibility.setAccessibilityValue(isSelected ? 1 : 0)
        accessibility.setAccessibilityHelp([item.machineBadgeHelp, item.subtitle].compactMap(\.self).joined(separator: ", "))
    }

    /// Records where the x draws (`drawn`, nil when hidden) and exposes it to accessibility
    /// clients there, or, on a closable tab that draws it only on hover, where hovering would
    /// draw it in `pill`; hides it otherwise. Agents press the x by its place. Rects are in the
    /// cell's flipped coordinates; the child's frame is in its tab's (unflipped) space.
    func setCloseButtonRect(_ drawn: CGRect?, pill: CGRect) {
        closeButtonRect = drawn
        let m = metrics, side = m.closeButtonSize
        // Point the hidden accessibility child where the close glyph will
        // actually appear on hover, including the centered narrow swap.
        // A pinned, protected or transition-hidden tab has no close child: a
        // pinned tab closes from its menu (Lawrence msg 19392).
        let hover = TabChromeVisibility.resolve(
            width: layer.bounds.width, isPinned: item.isPinned, isSelected: isSelected,
            isHovered: true, isClosable: item.isClosable, style: style, metrics: m)
        let hoverRect = hover.closeButtonOriginX(pillWidth: pill.width, metrics: m).map { x in
            CGRect(x: pixel(x), y: pixel(pill.height / 2 - side / 2), width: side, height: side)
        }
        let rect = drawn ?? hoverRect
        guard let rect else { return accessibility.closeButton.setAccessibilityFrameInParentSpace(.zero) }
        let height = layer.bounds.height
        accessibility.closeButton.setAccessibilityFrameInParentSpace(
            CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height))
    }
}
