import Foundation

/// Presentation controls that stay attached to a notification while policy
/// hooks rewrite its text or its target follows a moved surface.
struct TerminalNotificationPresentation: Hashable, Sendable {
    enum Delivery: String, Hashable, Sendable {
        case settings
        case system
        case dynamicNotch
    }

    struct Action: Hashable, Sendable {
        let id: String
        let title: String
    }

    struct Input: Hashable, Sendable {
        enum Kind: String, Hashable, Sendable {
            case text
            case secure
        }

        let id: String
        let label: String
        let placeholder: String
        let initialValue: String
        let kind: Kind
    }

    let delivery: Delivery
    let iconSymbolName: String?
    let actions: [Action]
    let inputs: [Input]
    let responseToken: UUID?
    let timeout: TimeInterval

    init(
        delivery: Delivery = .settings,
        iconSymbolName: String? = nil,
        actions: [Action] = [],
        inputs: [Input] = [],
        responseToken: UUID? = nil,
        timeout: TimeInterval = 8
    ) {
        self.delivery = delivery
        self.iconSymbolName = iconSymbolName
        self.actions = actions
        self.inputs = inputs
        self.responseToken = responseToken
        self.timeout = timeout
    }
}
