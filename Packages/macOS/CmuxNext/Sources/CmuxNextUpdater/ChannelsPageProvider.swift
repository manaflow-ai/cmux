import CmuxUpdater
public import CmuxNextPages
public import CmuxNextSettings

/// Settings > Updates' Channels card (`cmux.settings.channels.*`), routed here by prefix: every
/// ring's recent builds, read on demand, and the Go Back button into a kept build of a slower
/// ring (``UpdaterService/returnToRing(_:build:)``, the person's click only).
@MainActor
public final class ChannelsPageProvider: PageProvider {
    public static let prefix = "cmux.settings.channels."
    private let updater: UpdaterService

    public init(updater: UpdaterService) {
        self.updater = updater
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.settings.channels.state":
            let ring = params["ring"]?.stringValue.flatMap(UpdateRing.init(rawValue:))
            guard let state = JSONValue(foundation: await updater.channelsPageState(ring: ring)) else {
                throw PageError(code: "cmux.page.unavailable", message: "no channels")
            }
            return state
        case "cmux.settings.channels.go_back":
            // It restarts the app into another build: the person's own click in Settings only.
            guard context.page == PageDescriptor.settings.id, context.userGesture else {
                throw PageError(code: "cmux.settings.user_only", message: "only you can go back to another build")
            }
            guard let ring = params["ring"]?.stringValue.flatMap(UpdateRing.init(rawValue:)),
                  let build = params["build"]?.stringValue else { throw PageError.invalidParams("ring and build") }
            if let failure = await updater.returnToRing(ring, build: build) { throw PageError(code: "cmux.page.refused", message: failure) }
            return .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }
}
