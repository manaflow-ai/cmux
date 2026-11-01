import AppKit
import CmuxNextDesign

/// What one tab row of the workspace hover card says: its detail line and its trailing text, from the
/// tab's facts and the card's `WorkspaceTabHoverCardStyle`. Pure, so tests read it without a view.
struct WorkspaceTabHoverCardLine: Equatable {
    /// The muted line under (or after) the title; never empty, the tab's kind when it has no other fact.
    var detail: String { parts.joined(separator: Self.separator) }
    /// The detail line's facts, in order.
    var parts: [String]
    /// Which of `parts` is the place (a folder or a host), the only part that may shorten to fit.
    var placeIndex: Int?
    /// The trailing column's text; nil when the style has none or the tab has no such fact.
    var trailing: String?
    /// The status word the line shows, for its tint; nil when idle.
    var stateWord: String?

    static let separator = " · "

    init(_ tab: SidebarTab, style: WorkspaceTabHoverCardStyle, now: Date) {
        var parts: [String] = []
        var placeIndex: Int?
        for field in style.detail where field != style.trailing {
            guard let text = Self.text(field, of: tab, now: now) else { continue }
            if field == .place { placeIndex = parts.count }
            parts.append(text)
        }
        // The chat's running subagents and commands come first and never shorten (Leo 2026-11-01, #30439).
        if let work = WorkspaceHoverCardWork.counts(subagents: tab.subagentsRunning, commands: tab.commandsRunning) {
            parts.insert(work, at: 0)
            placeIndex = placeIndex.map { $0 + 1 }
        }
        if parts.isEmpty { parts = [Self.kindWord(tab.kind)] }
        self.parts = parts
        self.placeIndex = placeIndex
        trailing = style.trailing.flatMap { Self.text($0, of: tab, now: now) }
        stateWord = Self.stateWord(tab.state)
    }

    /// The detail line in at most `width` points of `font`: only the place shortens (Lawrence msg 19245:
    /// "not showing enough details per each"), keeping its last path component or its host's end; the
    /// state and the time never shorten.
    func detail(fitting width: CGFloat, font: NSFont) -> String {
        guard let placeIndex, Self.width(detail, font) > width else { return detail }
        var others = parts
        others[placeIndex] = ""
        let room = width - Self.width(others.joined(separator: Self.separator), font)
        var fitted = parts
        fitted[placeIndex] = Self.fit(place: parts[placeIndex], width: room, font: font)
        return fitted.joined(separator: Self.separator)
    }

    /// `place` in `width` points: whole when it fits, else its leading part, an ellipsis and its last path
    /// component ("~/fun/…/macOS"); a component or host too long alone loses its middle ("cmux-…-next").
    static func fit(place: String, width: CGFloat, font: NSFont) -> String {
        guard Self.width(place, font) > width else { return place }
        let components = place.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.count > 1, let last = components.last, !last.isEmpty {
            let tail = "/" + last
            var head = String(place.dropLast(tail.count))
            while !head.isEmpty, Self.width(head + "…" + tail, font) > width { head.removeLast() }
            if !head.isEmpty { return head + "…" + tail }
            if Self.width("…" + tail, font) <= width { return "…" + tail }
            return middle(last, width: width, font: font)
        }
        return middle(place, width: width, font: font)
    }

    /// `text` with its middle cut to fit `width` (at least its first and last characters).
    private static func middle(_ text: String, width: CGFloat, font: NSFont) -> String {
        var head = text.count / 2, tail = text.count - head
        func make() -> String { String(text.prefix(head)) + "…" + String(text.suffix(tail)) }
        while (head > 1 || tail > 1), Self.width(make(), font) > width {
            if head >= tail { head -= 1 } else { tail -= 1 }
        }
        return make()
    }

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// One fact of `tab` as the card writes it; nil when the tab has none.
    static func text(_ field: WorkspaceTabHoverCardStyle.Field, of tab: SidebarTab, now: Date) -> String? {
        switch field {
        case .kind: kindWord(tab.kind)
        case .place: nonEmpty(tab.kind == .browser ? tab.host : tab.folder)
        case .branch: nonEmpty(tab.branch)
        case .state: stateWord(tab.state)
        case .time: tab.lastActivity.flatMap { WorkspaceHoverCardContent.age(since: $0, now: now) }
        }
    }

    /// The status a tab's row says: nothing for an idle tab (a shell at rest is not "Done").
    static func stateWord(_ state: StatusIndicatorState) -> String? {
        if case .paused = state { return Strings.activityPaused }
        if state.isWorking || state.isLoading { return Strings.priorityWorking }
        if case .success = state { return Strings.activityDone }
        return Strings.activity(state)
    }

    /// What the tab is, in words.
    static func kindWord(_ kind: SidebarTabKind) -> String {
        switch kind {
        case .terminal: Strings.hoverCardKindTerminal
        case .remoteTerminal: Strings.hoverCardKindRemoteTerminal
        case .browser: Strings.hoverCardKindBrowser
        case .conversation, .agentChat: Strings.hoverCardKindAgentChat
        case .newTab, .other: Strings.hoverCardKindTab
        }
    }

    /// The title a tab row shows: a blank page reads "New Tab" (the owner, on the gallery).
    static func title(_ tab: SidebarTab) -> String {
        tab.kind == .browser && tab.title == "about:blank" ? Strings.hoverCardNewTab : tab.title
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
