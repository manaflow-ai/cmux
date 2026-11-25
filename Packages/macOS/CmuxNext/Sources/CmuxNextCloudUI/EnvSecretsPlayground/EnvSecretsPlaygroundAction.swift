#if DEBUG
public import CmuxNextActions

/// DEBUG ONLY: binds `debug.envSecretsPlayground` (Command Palette > Environment Secrets Playground,
/// DEV builds): opens ``EnvSecretsPlayground``. Its `variant` argument (1 to 3) picks the direction,
/// `state` (0 to 9) the state and `dark` the look; none keeps what the window shows.
@MainActor
public struct EnvSecretsPlaygroundAction {
    /// The action's id.
    public static let id: ActionID = "debug.envSecretsPlayground"

    public init() {}

    /// Binds the action: one window per registry, raised when it is already open.
    public func bind(into registry: ActionRegistry) {
        let playground = EnvSecretsPlayground()
        registry.bindEffect(Self.id, effect: { invocation in
            playground.show(direction: invocation["variant"]?.intValue, state: invocation["state"]?.intValue,
                            dark: invocation["dark"]?.boolValue)
            return .done
        })
    }
}
#endif
