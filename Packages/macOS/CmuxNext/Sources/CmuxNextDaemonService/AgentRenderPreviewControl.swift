package import CmuxNextAgentPane
package import CmuxNextControl
import Foundation
package import WebKit

/// Registers the local chat capture on the control transport without app service dependencies.
@MainActor
package final class AgentRenderPreviewControl {
    private let requests = AgentRenderPreviewRequests()

    package init() {}

    package func methods(pane: @escaping @MainActor (String) -> AgentPaneView?,
                         park: @escaping @MainActor (WKWebView) -> (@MainActor () -> Void)) -> [ControlMethod] {
        [
            // WebKit is main-actor-only; rendering suspends outside the bounded mutation queue.
            .async("agent.render_preview") { [weak self] call in
                guard let self else { throw CancellationError() }
                do {
                    return try await self.requests.capture(call.params, pane: pane, park: park)
                } catch let error as AgentRenderPreviewFailure {
                    throw ControlError(code: error.code, message: error.message)
                }
            }.withDeadline(.fixed(.seconds(12))),
        ]
    }
}
