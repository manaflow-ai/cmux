public import Foundation

/// The full document exchanged with a notification-policy hook: the wire
/// version, the notification payload, its context, the effects to apply, and an
/// optional `stop` flag that halts further hook evaluation. Encoded to a hook's
/// stdin and reconstructed by merging the hook's stdout patch back in.
public struct TerminalNotificationPolicyEnvelope: Codable, Sendable, Equatable {
    /// The wire format version.
    public var version: Int = 1
    /// The notification payload.
    public var notification: TerminalNotificationPolicyPayload
    /// The contextual signals for policy evaluation.
    public var context: TerminalNotificationPolicyContext
    /// The effects to apply.
    public var effects: TerminalNotificationPolicyEffects = TerminalNotificationPolicyEffects()
    /// When `true`, no further hooks are evaluated.
    public var stop: Bool?

    /// Creates a policy envelope. `version`, `effects`, and `stop` default to
    /// the initial values used before any hook runs.
    public init(
        version: Int = 1,
        notification: TerminalNotificationPolicyPayload,
        context: TerminalNotificationPolicyContext,
        effects: TerminalNotificationPolicyEffects = TerminalNotificationPolicyEffects(),
        stop: Bool? = nil
    ) {
        self.version = version
        self.notification = notification
        self.context = context
        self.effects = effects
        self.stop = stop
    }

    /// Decodes a hook's stdout JSON as a partial patch and returns a new
    /// envelope with the patch merged in. Throws if the output is not valid
    /// patch JSON.
    public func merging(hookOutput data: Data) throws -> TerminalNotificationPolicyEnvelope {
        let patch = try JSONDecoder().decode(TerminalNotificationPolicyEnvelopePatch.self, from: data)
        return patch.merged(into: self)
    }
}

/// Partial, hook-supplied overrides for ``TerminalNotificationPolicyEnvelope``.
/// Any field omitted from the hook output leaves the corresponding envelope
/// value untouched.
struct TerminalNotificationPolicyEnvelopePatch: Decodable {
    var version: Int?
    var notification: TerminalNotificationPolicyPayloadPatch?
    var context: TerminalNotificationPolicyContextPatch?
    var effects: TerminalNotificationPolicyEffectsPatch?
    var stop: Bool?

    func merged(into envelope: TerminalNotificationPolicyEnvelope) -> TerminalNotificationPolicyEnvelope {
        TerminalNotificationPolicyEnvelope(
            version: version ?? envelope.version,
            notification: notification?.merged(into: envelope.notification) ?? envelope.notification,
            context: context?.merged(into: envelope.context) ?? envelope.context,
            effects: effects?.merged(into: envelope.effects) ?? envelope.effects,
            stop: stop ?? envelope.stop
        )
    }
}
