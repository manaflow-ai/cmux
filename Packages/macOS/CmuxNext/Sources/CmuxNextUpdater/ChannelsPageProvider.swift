public import CmuxNextPages
public import CmuxNextSettings

/// Settings > Updates' Channels card (`cmux.settings.channels.*`), routed here by prefix: every
/// ring's recent builds, read on demand. It only reads; installing a build is a later gesture.
@MainActor
public final class ChannelsPageProvider: PageProvider {
    public static let prefix = "cmux.settings.channels."
    private let updater: UpdaterService

    public init(updater: UpdaterService) {
        self.updater = updater
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == "cmux.settings.channels.state" else { throw PageError.unknownOp(op) }
        guard let state = JSONValue(foundation: await updater.channelsPageState()) else {
            throw PageError(code: "cmux.page.unavailable", message: "no channels")
        }
        return state
    }
}
