#if os(iOS)
import Observation

@MainActor
@Observable
final class TerminalComposerSubmitRouter {
    var action: (@MainActor () async -> Void)?

    var isAgentGUIRouting: Bool {
        action != nil
    }

    init(action: (@MainActor () async -> Void)? = nil) {
        self.action = action
    }

    @MainActor
    func submit(fallback: @MainActor () async -> Void) async {
        if let action {
            await action()
        } else {
            await fallback()
        }
    }
}
#endif
