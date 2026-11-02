import AppKit
import CmuxNextDesign

/// What one tab row of the workspace hover card says: its detail line and its trailing text, from the
/// tab's facts and the card's `WorkspaceTabHoverCardStyle`. Pure, so tests read it without a view.
struct WorkspaceTabHoverCardLine: Equatable {
    /// The muted line under (or after) the title; empty when the tab has no fact worth a line.
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

    /// `machine`: where the tab's workspace runs, as the card names it (`machineWord`); nil leaves the
    /// machine out (a tab elsewhere still names its own).
    init(_ tab: SidebarTab, style: WorkspaceTabHoverCardStyle, now: Date, machine: SidebarMachine? = nil) {
        var parts: [String] = []
        var placeIndex: Int?
        let title = Self.title(tab)
        for field in style.detail where field != style.trailing {
            guard let text = Self.text(field, of: tab, now: now, machine: machine, style: style),
                  // Never the same text twice: a part that repeats the title ("~" under "~") says nothing.
                  text.caseInsensitiveCompare(title) != .orderedSame, !parts.contains(text) else { continue }
            if field == .place { placeIndex = parts.count }
            parts.append(text)
        }
        // The chat's running subagents and commands come first and never shorten (Leo 2026-11-01, #30439).
        if let work = WorkspaceHoverCardWork.counts(subagents: tab.subagentsRunning, commands: tab.commandsRunning) {
            parts.insert(work, at: 0)
            placeIndex = placeIndex.map { $0 + 1 }
        }
        // No fact, no line: never a bare kind word ("New Tab" over "Tab", Leo 2026-11-01).
        self.parts = parts
        self.placeIndex = placeIndex
        trailing = style.trailing.flatMap { Self.text($0, of: tab, now: now, machine: machine, style: style) }
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
    static func text(_ field: WorkspaceTabHoverCardStyle.Field, of tab: SidebarTab, now: Date, machine: SidebarMachine? = nil,
                     style: WorkspaceTabHoverCardStyle = .standard) -> String? {
        switch field {
        case .kind: kindWord(tab.kind)
        case .place: tab.kind == .browser ? pagePlace(tab) : nonEmpty(tab.folder)
        case .branch: nonEmpty(tab.branch)
        case .state: stateWord(tab.state)
        case .time: tab.lastActivity.flatMap { WorkspaceHoverCardContent.age(since: $0, now: now) }
        case .model: tab.kind == .agentChat || tab.kind == .conversation ? nonEmpty(tab.model) : nil
        case .command: tab.kind == .terminal || tab.kind == .remoteTerminal ? nonEmpty(tab.command) : nil
        case .machine: machineText(tab, workspace: machine, namesLocal: style.namesLocalMachine)
        }
    }

    /// A page's place: its host and path ("github.com/manaflow-ai/cmux/pull/12"), or only the path when
    /// the title already is the host (a page whose title never loaded), so the line never repeats the title.
    static func pagePlace(_ tab: SidebarTab) -> String? {
        guard let host = nonEmpty(tab.host) else { return nil }
        let path = tab.path ?? ""
        if host.caseInsensitiveCompare(title(tab)) == .orderedSame { return nonEmpty(path) }
        return host + path
    }

    /// Where an agent chat or terminal tab runs; nil for pages and New Tab pages, which run here.
    static func machineText(_ tab: SidebarTab, workspace: SidebarMachine?, namesLocal: Bool) -> String? {
        switch tab.kind {
        case .terminal, .remoteTerminal, .agentChat, .conversation: break
        case .browser, .newTab, .other: return nil
        }
        if let own = nonEmpty(tab.machine) { return own }
        guard let workspace else { return nil }
        if workspace.kind == .local { return namesLocal ? Strings.hoverCardThisMac : nil }
        return machineWord(workspace)
    }

    /// A machine as the card names it: "This Mac", "Cloud", or its name (the card's host row's words).
    static func machineWord(_ machine: SidebarMachine) -> String {
        switch machine.kind {
        case .local: Strings.hoverCardThisMac
        case .cloud: Strings.hoverCloud
        case .ssh, .server: machine.name
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
