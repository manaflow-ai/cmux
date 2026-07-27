public import Foundation

/// Validated, app-independent presentation controls for a notification create
/// request. The app maps this value to its concrete presentation model.
public struct ControlNotificationPresentation: Sendable, Equatable {
    public enum Delivery: String, Sendable {
        case settings
        case system
        case dynamicNotch
    }

    public struct Action: Sendable, Equatable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public struct Input: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case text
            case secure
        }

        public let id: String
        public let label: String
        public let placeholder: String
        public let initialValue: String
        public let kind: Kind

        public init(
            id: String,
            label: String,
            placeholder: String,
            initialValue: String,
            kind: Kind
        ) {
            self.id = id
            self.label = label
            self.placeholder = placeholder
            self.initialValue = initialValue
            self.kind = kind
        }
    }

    public let notificationID: UUID
    public let delivery: Delivery
    public let iconSymbolName: String?
    public let actions: [Action]
    public let inputs: [Input]
    public let responseToken: UUID?
    public let timeout: TimeInterval

    public init(
        notificationID: UUID,
        delivery: Delivery,
        iconSymbolName: String?,
        actions: [Action],
        inputs: [Input],
        responseToken: UUID?,
        timeout: TimeInterval
    ) {
        self.notificationID = notificationID
        self.delivery = delivery
        self.iconSymbolName = iconSymbolName
        self.actions = actions
        self.inputs = inputs
        self.responseToken = responseToken
        self.timeout = timeout
    }
}
