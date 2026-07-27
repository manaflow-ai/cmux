public import Foundation

/// Validated, app-independent presentation controls for a notification create
/// request. The app maps this value to its concrete presentation model.
public struct ControlNotificationPresentation: Sendable, Equatable {
    private enum ParseError: Error {
        case invalid
    }

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
        notificationID: UUID = UUID(),
        delivery: Delivery = .settings,
        iconSymbolName: String? = nil,
        actions: [Action] = [],
        inputs: [Input] = [],
        responseToken: UUID? = nil,
        timeout: TimeInterval = 8
    ) {
        self.notificationID = notificationID
        self.delivery = delivery
        self.iconSymbolName = iconSymbolName
        self.actions = actions
        self.inputs = inputs
        self.responseToken = responseToken
        self.timeout = timeout
    }

    /// Parses and validates the presentation fields accepted by every
    /// notification creation entrypoint.
    public init?(parameters: [String: JSONValue]) {
        do {
            let notificationID = try Self.parseNotificationID(parameters)
            let delivery = try Self.parseDelivery(parameters)
            let icon = try Self.parseIcon(parameters)
            let actions = try Self.parseActions(parameters)
            let inputs = try Self.parseInputs(parameters)
            let responseToken = try Self.parseResponseToken(parameters)
            let timeout = try Self.parseTimeout(parameters)
            guard (actions.isEmpty && inputs.isEmpty && responseToken == nil)
                    || delivery == .dynamicNotch else {
                return nil
            }
            self.init(
                notificationID: notificationID,
                delivery: delivery,
                iconSymbolName: icon,
                actions: actions,
                inputs: inputs,
                responseToken: responseToken,
                timeout: timeout
            )
        } catch {
            return nil
        }
    }

    private static func parseNotificationID(
        _ parameters: [String: JSONValue]
    ) throws -> UUID {
        guard let value = parameters["notification_id"] else { return UUID() }
        guard case .string(let rawValue) = value,
              let notificationID = UUID(uuidString: rawValue) else {
            throw ParseError.invalid
        }
        return notificationID
    }

    private static func parseDelivery(
        _ parameters: [String: JSONValue]
    ) throws -> Delivery {
        let rawValue: String
        if let value = parameters["delivery"] {
            guard case .string(let string) = value else { throw ParseError.invalid }
            rawValue = string
        } else {
            rawValue = "settings"
        }
        switch rawValue {
        case "settings", "default":
            return .settings
        case "system":
            return .system
        case "dynamicNotch", "notch":
            return .dynamicNotch
        default:
            throw ParseError.invalid
        }
    }

    private static func parseIcon(
        _ parameters: [String: JSONValue]
    ) throws -> String? {
        guard let value = parameters["icon"] else { return nil }
        guard case .string(let rawValue) = value else { throw ParseError.invalid }
        let icon = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard icon.count <= 128 else { throw ParseError.invalid }
        return icon.isEmpty ? nil : icon
    }

    private static func parseActions(
        _ parameters: [String: JSONValue]
    ) throws -> [Action] {
        guard let value = parameters["actions"] else { return [] }
        guard case .array(let rawActions) = value,
              rawActions.count <= 4 else {
            throw ParseError.invalid
        }
        var actions: [Action] = []
        var actionIDs: Set<String> = []
        let reservedIDs: Set<String> = [
            "open", "dismiss", "timeout", "replaced", "dismissed",
        ]
        for rawAction in rawActions {
            guard case .object(let object) = rawAction,
                  Set(object.keys).isSubset(of: ["id", "title"]),
                  case .string(let rawID)? = object["id"],
                  case .string(let rawTitle)? = object["title"] else {
                throw ParseError.invalid
            }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                  id.count <= 64,
                  !title.isEmpty,
                  title.count <= 80,
                  !reservedIDs.contains(id),
                  controlIdentifierIsValid(id),
                  actionIDs.insert(id).inserted else {
                throw ParseError.invalid
            }
            actions.append(Action(id: id, title: title))
        }
        return actions
    }

    private static func parseInputs(
        _ parameters: [String: JSONValue]
    ) throws -> [Input] {
        guard let value = parameters["inputs"] else { return [] }
        guard case .array(let rawInputs) = value,
              rawInputs.count <= 4 else {
            throw ParseError.invalid
        }
        var inputs: [Input] = []
        var inputIDs: Set<String> = []
        for rawInput in rawInputs {
            guard case .object(let object) = rawInput,
                  Set(object.keys).isSubset(of: [
                      "id", "label", "placeholder", "initial_value", "secure",
                  ]),
                  case .string(let rawID)? = object["id"],
                  case .string(let rawLabel)? = object["label"] else {
                throw ParseError.invalid
            }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let placeholder = try optionalString(object["placeholder"]) ?? ""
            let initialValue = try optionalString(object["initial_value"]) ?? ""
            let kind: Input.Kind
            switch object["secure"] {
            case .bool(true)?:
                kind = .secure
            case .bool(false)?, nil:
                kind = .text
            default:
                throw ParseError.invalid
            }
            guard !id.isEmpty,
                  id.count <= 64,
                  controlIdentifierIsValid(id),
                  inputIDs.insert(id).inserted,
                  !label.isEmpty,
                  label.count <= 80,
                  placeholder.count <= 160,
                  initialValue.count <= 4_096 else {
                throw ParseError.invalid
            }
            inputs.append(Input(
                id: id,
                label: label,
                placeholder: placeholder,
                initialValue: initialValue,
                kind: kind
            ))
        }
        return inputs
    }

    private static func parseResponseToken(
        _ parameters: [String: JSONValue]
    ) throws -> UUID? {
        guard let value = parameters["response_token"] else { return nil }
        guard case .string(let rawValue) = value,
              let token = UUID(uuidString: rawValue) else {
            throw ParseError.invalid
        }
        return token
    }

    private static func parseTimeout(
        _ parameters: [String: JSONValue]
    ) throws -> TimeInterval {
        let timeout: TimeInterval
        switch parameters["timeout"] {
        case .double(let value)?:
            timeout = value
        case .int(let value)?:
            timeout = Double(value)
        case nil:
            timeout = 8
        default:
            throw ParseError.invalid
        }
        guard timeout.isFinite, (0...86_400).contains(timeout) else {
            throw ParseError.invalid
        }
        return timeout
    }

    private static func optionalString(_ value: JSONValue?) throws -> String? {
        guard let value else { return nil }
        guard case .string(let string) = value else { throw ParseError.invalid }
        return string
    }

    private static func controlIdentifierIsValid(_ identifier: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
        )
        return identifier.unicodeScalars.allSatisfy(allowed.contains)
    }
}
