public import Foundation

extension CloudTunnelController {
    /// Turns the tunnel on or off for `cmux cloud tunnel on|off` and MCP, and answers the status
    /// the change settles in.
    ///
    /// Only the person (Settings, or the CLI in their terminal) can turn the tunnel on: an agent
    /// cannot open the Mac to the Cloud network. The change goes through the setting first, the
    /// same path Settings takes (``follow(_:)``); a second request for the same direction joins
    /// the first (``request(on:)``).
    ///
    /// - Parameters:
    ///   - on: `true` to turn the tunnel on, `false` to turn it off.
    ///   - byPerson: Whether the person asked (Settings, or the CLI), not an agent.
    ///   - settingIsOn: The setting's current value, or `nil` when there are no settings to write.
    ///   - writeSetting: Writes the setting; called only when it differs from `on`.
    /// - Returns: The status the change settles in.
    /// - Throws: ``CloudTunnelRefusal`` when an agent asks to turn it on or the build cannot run
    ///   the tunnel; any error `writeSetting` throws.
    public func change(on: Bool, byPerson: Bool, settingIsOn: Bool?,
                       writeSetting: @MainActor (Bool) async throws -> Void) async throws -> CloudTunnelStatus {
        if on, !byPerson { throw CloudTunnelRefusal(message: CloudTunnelStatus.agentRefusal) }
        if case .unavailable(let why) = status { throw CloudTunnelRefusal(message: why) }
        if let settingIsOn, settingIsOn != on { try await writeSetting(on) }
        return await request(on: on)
    }
}
