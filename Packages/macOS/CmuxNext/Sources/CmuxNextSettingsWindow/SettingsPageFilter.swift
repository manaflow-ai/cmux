public import CmuxNextDesign
public import CmuxNextSettings
public import Foundation

/// The one-page layout's search: the page stays, and only the matching
/// rows, cards and buttons show. Groups and sections left without a match
/// are hidden.
public struct SettingsPageFilter: Equatable, Sendable {
    /// Anchor ids of the matching entries.
    public let anchors: Set<String>
    /// Sections with at least one match (Keyboard when a shortcut matches).
    public let sections: Set<SettingsSection>

    public init(matches: [SettingsSearchEntry], shortcutsMatch: Bool) {
        anchors = Set(matches.map(\.id))
        var sections = Set(matches.map(\.section))
        if shortcutsMatch { sections.insert(.keyboard) }
        self.sections = sections
    }

    public func shows(_ anchorID: String) -> Bool { anchors.contains(anchorID) }

    /// `groups` with only the matching rows; a group left empty is dropped.
    public func filter(_ groups: [SettingsGroup]) -> [SettingsGroup] {
        groups.compactMap { group in
            let kept = group.settings.filter { shows($0.id) }
            return kept.isEmpty ? nil : SettingsGroup(title: group.title, settings: kept)
        }
    }

    /// The sections of `order` that keep a match, in order.
    public func filter(_ order: [SettingsSection]) -> [SettingsSection] {
        order.filter { sections.contains($0) }
    }
}

/// The one-page sidebar follows the scroll position: the selected section
/// is the last one whose header has reached `line` (points below the top
/// of the visible area). Pure, so the rule is tested without a window.
public enum SettingsScrollSpy {
    /// `offsets` are header tops relative to the visible area's top, for
    /// the sections on the page; `order` is page order. Before any header
    /// reaches the line, the first section is selected.
    public static func section(order: [SettingsSection], offsets: [SettingsSection: CGFloat], line: CGFloat) -> SettingsSection? {
        var current: SettingsSection?
        for section in order {
            guard let offset = offsets[section] else { continue }
            if offset > line { break }
            current = section
        }
        return current ?? order.first
    }
}

/// How a jumped-to row's highlight goes away: under full motion it fades
/// out over the Motion `highlight` token; under Reduce Motion (or with
/// animations off) it stays at full strength that long and then goes in
/// one frame, without animation.
public struct SettingsHighlightPlan: Equatable, Sendable {
    /// Seconds at full strength before it starts to go.
    public let hold: TimeInterval
    /// Seconds the fade-out takes; 0 removes it at once.
    public let fade: TimeInterval

    public var animates: Bool { fade > 0 }

    public static func make(policy: MotionPolicy) -> SettingsHighlightPlan {
        let fade = policy.duration(MotionFade.highlight)
        guard policy.reduceMotion || fade == 0 else { return SettingsHighlightPlan(hold: 0, fade: fade) }
        return SettingsHighlightPlan(hold: MotionFade.highlight.baseDuration * max(policy.speed.timeScale, 1), fade: 0)
    }
}
