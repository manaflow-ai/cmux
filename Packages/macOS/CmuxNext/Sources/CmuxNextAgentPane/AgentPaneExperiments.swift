public import CmuxNextSettings
import Foundation

/// Settings > Advanced > Experiments (`experiments.*` in cmux.json): taste prototypes, one switch
/// each, all off by default. The App (AgentPanePageSettings) sets ``switches`` from cmux.json and
/// pushes them to every open page as one object, `{"glassToolbarGroups": true, ...}`, the
/// `experiments` event (the page's experiments/switches.ts); a page that loads again gets them with
/// the rest of the view's state (``AgentPanePageHost/currentEvents(_:)``). A new prototype adds only
/// its schema row. Not an AgentPaneView extension: that type is at its size limit.
@MainActor
public final class AgentPaneExperiments {
    public static let shared = AgentPaneExperiments()
    /// Every `experiments.*` toggle by its last path part, on or off.
    public private(set) var switches: [String: Bool] = [:]
    /// What each page was last given, so the App's push to every view sends only a change.
    private let delivered = NSMapTable<AgentPaneView, NSDictionary>.weakToStrongObjects()

    /// Sets the switches; returns whether they changed.
    @discardableResult
    public func set(_ switches: [String: Bool]) -> Bool {
        guard switches != self.switches else { return false }
        self.switches = switches
        return true
    }

    /// The switches as a page host event; `view` counts them as given.
    func event(for view: AgentPaneView) -> AgentPageEvent {
        delivered.setObject(switches as NSDictionary, forKey: view)
        return Self.event(switches)
    }

    /// Gives `view`'s page the switches, unless it already has them; `again`: a new document (load,
    /// handshake), which has none whatever was given before.
    public func push(to view: AgentPaneView, again: Bool = false) {
        guard again || delivered.object(forKey: view) as? [String: Bool] != switches else { return }
        let event = event(for: view)
        view.deliver([event], scripts: [Self.script(switches)])
    }

    nonisolated static func json(_ switches: [String: Bool]) -> JSONValue { .object(switches.mapValues(JSONValue.bool)) }

    nonisolated static func event(_ switches: [String: Bool]) -> AgentPageEvent {
        AgentPageEvent(kind: "experiments", value: json(switches))
    }

    /// The script that gives a loaded page on the old host the switches.
    nonisolated static func script(_ switches: [String: Bool]) -> String {
        "window.cmuxAcpmuxBridge?.applyExperiments?.(\(json(switches).compactText));"
    }
}
