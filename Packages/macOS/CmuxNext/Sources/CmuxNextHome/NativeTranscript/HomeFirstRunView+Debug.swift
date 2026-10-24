#if DEBUG || CMUX_BENCH_HOOKS
import AppKit

/// DEBUG: the `home-chief` capture scene reads the listed agents and clicks one.
extension HomeFirstRunView {
    /// The listed agents with whether each row is shown: the panel hides
    /// the rows that do not fit its height.
    var debugAgents: [HomeDebugAgentRow] {
        zip(agents, agentRows).map { HomeDebugAgentRow(id: $0.id, title: $0.title, status: $0.status, shown: !$1.isHidden) }
    }

    /// The bottom edge of the lowest part the panel shows, in its own
    /// coordinates; nil when it shows none (`home-chief-long-draft`).
    var debugShownBottom: CGFloat? {
        ([hero, switchCard, agentsHeader] + rows).filter { !$0.isHiddenOrHasHiddenAncestor }
            .map { convert($0.bounds, from: $0).maxY }.max()
    }

    /// Which of the hero, the Switching card and the action rows show.
    var debugShownParts: [String: Bool] {
        ["hero": !hero.isHiddenOrHasHiddenAncestor, "switch_card": !switchCard.isHiddenOrHasHiddenAncestor,
         "action_rows": actionRows.contains { !$0.isHiddenOrHasHiddenAncestor }]
    }

    /// Clicks agent row `index`: a mouse down and up at its centre sent
    /// through its window, which hit-tests them as a pointer click, or with
    /// `pointer` false VoiceOver's press. Returns the tab id the row's click
    /// handed to `onAgent`; nil when the click never reached it (the row is
    /// missing or hidden, or another view is under its centre).
    func debugClickAgent(_ index: Int, pointer: Bool) -> String? {
        guard agentRows.indices.contains(index) else { return nil }
        let row = agentRows[index]
        guard !row.isHiddenOrHasHiddenAncestor, let window = row.window, let content = window.contentView else { return nil }
        let handler = onAgent
        var opened: String?
        onAgent = { id in
            opened = id
            handler(id)
        }
        defer { onAgent = handler }
        guard pointer else {
            _ = row.accessibilityPerformPress()
            return opened
        }
        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        guard let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point),
              hit === row || hit.isDescendant(of: row) else { return nil }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return opened }
            window.sendEvent(event)
        }
        return opened
    }
}

/// DEBUG: one listed agent as the first-run panel shows it.
public struct HomeDebugAgentRow: Sendable {
    public var id: String
    public var title: String
    public var status: HomeAgentGlance.Status
    /// The panel did not hide the row for its height.
    public var shown: Bool
}
#endif
