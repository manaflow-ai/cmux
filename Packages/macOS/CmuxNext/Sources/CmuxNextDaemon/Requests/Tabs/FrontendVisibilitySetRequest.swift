/// `frontend.visibility.set` (cmux-tui/spec/events.md "Frontend visibility", cmux-tui-core
/// server/frontend_visibility.rs): the whole set of surfaces this app shows. On this
/// connection's subscription the daemon holds the latest-state events (title, agent, program status, output,
/// scroll) of every other surface and delivers them once per aligned second, or at once when the surface shows;
/// structural events and exits never wait. `visible: nil` clears the scope, and the scope ends with the connection.
public struct FrontendVisibilitySetRequest: DaemonRequest, Equatable {
    public typealias Response = EmptyResponse
    public static let commandName: DaemonCommandName = "frontend.visibility.set"
    public static var requiredCapability: String? { DaemonCapability.frontendVisibility.rawValue }

    /// The surfaces shown now, in ascending order (one spelling per set); nil shows every surface.
    public var visible: [SurfaceID]?

    public init(visible: [SurfaceID]?) {
        self.visible = visible
    }

    enum CodingKeys: String, CodingKey {
        case visible
    }

    /// `visible` is always on the line: `null` is the clear, not an omitted field.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(visible, forKey: .visible)
    }
}
