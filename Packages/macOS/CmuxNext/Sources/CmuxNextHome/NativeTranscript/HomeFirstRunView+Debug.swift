#if DEBUG
import AppKit

/// DEBUG: the `home-chief` capture scene reads the listed agents and clicks one.
extension HomeFirstRunView {
    /// The listed agents with whether each row is shown (rows that do not
    /// fit the panel are hidden).
    var debugAgents: [HomeDebugAgentRow] {
        zip(agents, agentRows).map { HomeDebugAgentRow(id: $0.id, title: $0.title, status: $0.status, shown: !$1.isHidden) }
    }

    /// Clicks agent row `index`: a mouse down and up at its centre sent
    /// through its window, which hit-tests them as a pointer click, or with
    /// `pointer` false VoiceOver's press. Returns the row's tab id; nil when
    /// the row is missing or hidden, or another view is under its centre.
    func debugClickAgent(_ index: Int, pointer: Bool) -> String? {
        guard agents.indices.contains(index), agentRows.indices.contains(index) else { return nil }
        let row = agentRows[index]
        guard !row.isHiddenOrHasHiddenAncestor, let window = row.window, let content = window.contentView else { return nil }
        guard pointer else { return row.accessibilityPerformPress() ? agents[index].id : nil }
        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        guard let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point),
              hit === row || hit.isDescendant(of: row) else { return nil }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return nil }
            window.sendEvent(event)
        }
        return agents[index].id
    }
}

/// DEBUG: one listed agent as the first-run panel shows it.
public struct HomeDebugAgentRow: Sendable {
    public var id: String
    public var title: String
    public var status: HomeAgentGlance.Status
    /// The row fits the panel and is on screen.
    public var shown: Bool
}
#endif
