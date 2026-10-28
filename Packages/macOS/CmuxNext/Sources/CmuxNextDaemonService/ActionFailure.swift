/// A typed reason a workspace/window/settings handler could not act. Thrown
/// from handlers bound with `bind(_:run:)`, it reaches the control socket
/// as `unavailable: <message>` through `ActionRegistry.refuse`.
public struct ActionFailure: Error, Hashable, CustomStringConvertible {
    public let message: String
    /// An explicit target names nothing: the control socket answers `not_found`.
    public var isNotFound = false
    /// A navigation or focus move with no target (R136): no notice for a
    /// keyboard or menu run; callers still get the message.
    public var isQuiet = false

    public init(message: String, isNotFound: Bool = false, isQuiet: Bool = false) {
        self.message = message
        self.isNotFound = isNotFound
        self.isQuiet = isQuiet
    }

    /// An action reached a service after the app's services were gone.
    public static var appClosing: ActionFailure { ActionFailure(message: RefusalStrings.appClosing) }

    /// The cmux-tui daemon does not serve `capability`.
    public static func needsDaemonCapability(_ capability: String) -> ActionFailure {
        ActionFailure(message: RefusalStrings.needsDaemonCapability(capability))
    }

    /// cmux-next has no implementation of `feature` yet.
    public static func needsAppCapability(_ feature: String) -> ActionFailure {
        ActionFailure(message: RefusalStrings.needsAppCapability(feature))
    }

    public static func invalidTarget(_ message: String) -> ActionFailure {
        ActionFailure(message: message)
    }

    public static func noTarget(_ message: String) -> ActionFailure {
        ActionFailure(message: message, isQuiet: true)
    }

    public static func notFound(_ message: String) -> ActionFailure {
        ActionFailure(message: message, isNotFound: true)
    }

    public var description: String { message }
}
