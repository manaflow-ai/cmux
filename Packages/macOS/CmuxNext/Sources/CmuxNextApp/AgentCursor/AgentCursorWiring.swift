import CmuxAgentCursor
import CmuxNextAgentCursor
import QuartzCore

/// App wiring of agent cursors that is not part of `AppServices` itself.
enum AgentCursorWiring {
    /// The visibility source with its change consumer: a tracked target that
    /// moves between input events (column scroll, minimize, tab or workspace
    /// switch) re-places the cursors of every content that follows it.
    static func makeVisibility(services: AppServices) -> AgentCursorVisibilitySource {
        let source = AgentCursorVisibilitySource(services: services)
        source.onChange = { [weak services] target, _ in
            guard let services else { return }
            placementsDidChange(target: target, in: services)
        }
        return source
    }

    /// Every window re-places the cursors whose last input went to `target`
    /// (a window that does not show it resolves it elsewhere and hides them).
    static func placementsDidChange(target: String, in services: AppServices) {
        for controller in services.windows.controllers {
            controller.agentCursor.placementsDidChange(target: target)
        }
    }

    /// The one app entry point for published agent input (the provider-link
    /// `input {event}` bridge and debug tools): every window gets it; only a
    /// window that draws the target makes its cursor layer.
    static func publish(_ event: AutomationInputEvent, in services: AppServices) {
        for controller in services.windows.controllers {
            controller.agentCursor.publish(event)
        }
    }

    /// One window's cursor slot on its window-level cursor layer
    /// (plans/cmux-next/agent-cursor.md), with a9's per-window resolver.
    static func slot(for controller: WindowController) -> AgentCursorWindowSlot {
        let services = controller.services
        let slot = AgentCursorWindowSlot(resolver: services.agentCursorVisibility.resolver(forWindow: controller.state.id)) {
            [weak controller] in (controller?.window as? ShellWindow)?.overlayLayer.agentCursorLayer ?? CALayer()
        }
        slot.onUntrack = { [weak services] target in services?.agentCursorVisibility.untrack(target) }
        return slot
    }

    /// Every window's cursor slot, for lease fan-out.
    static func slots(in services: AppServices) -> [AgentCursorWindowSlot] {
        services.windows.controllers.map(\.agentCursor)
    }
}
