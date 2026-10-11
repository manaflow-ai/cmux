import AppKit
import CmuxNextSettings

/// The agent last picked on the new tab screen, kept on this Mac across
/// relaunches (decision Q3: app-local memory; one input without a mode,
/// R86). Client view state, so it never reaches the daemon.
/// Also the template each window's dots last picked (cx-l1jv), for that
/// window's next pages; it lives as long as the window.
@MainActor
final class NewTabChoiceMemory {
    private static let agentKey = "newTab.lastAgent"
    private let defaults: UserDefaults
    private let templates = NSMapTable<NSWindow, NSString>.weakToStrongObjects()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var agent: String? { defaults.string(forKey: Self.agentKey).flatMap { $0.isEmpty ? nil : $0 } }

    /// A value the page should never send (empty, too long) is ignored.
    func remember(agent: String) {
        guard !agent.isEmpty, agent.count <= 128 else { return }
        defaults.set(agent, forKey: Self.agentKey)
    }

    /// The template `window`'s dots last picked; nil when they picked none (the setting applies).
    func template(in window: NSWindow?) -> NewTabTemplate? {
        window.flatMap { templates.object(forKey: $0) }.flatMap { NewTabTemplate(rawValue: $0 as String) }
    }

    func remember(template: NewTabTemplate, in window: NSWindow?) {
        guard let window else { return }
        templates.setObject(template.rawValue as NSString, forKey: window)
    }
}
