import CmuxNextCompat
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
    /// The card's acpmux daemon line, its title and value (the app's local daemon); nil without one.
    private let daemon: (@Sendable () async -> (title: String, value: String)?)?
    /// The card's row of other machines (the daemon update board): those that cannot update in
    /// place and those whose update failed, one line each; nil when none. Read with the card, then
    /// pushed on ``machinesStream`` as it changes while the card shows.
    private let machines: (@MainActor @Sendable () -> (title: String, lines: [String])?)?

    /// The row of other machines as it changes (its new value, null when none), while a page
    /// subscribes: a failure that comes while Settings > Updates shows (or its Details opened it)
    /// shows in the row at once.
    public static let machinesStream = "cmux.settings.channels.machines.changed"

    public init(updater: UpdaterService, daemon: (@Sendable () async -> (title: String, value: String)?)? = nil,
                machines: (@MainActor @Sendable () -> (title: String, lines: [String])?)? = nil) {
        self.updater = updater
        self.daemon = daemon
        self.machines = machines
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.settings.channels.state":
            let ring = params["ring"]?.stringValue.flatMap(UpdateRing.init(rawValue:))
            // The daemon line is read beside the feed: one status call, never polled.
            let daemon = self.daemon
            async let line: (title: String, value: String)? = daemon?()
            var page = await updater.channelsPageState(ring: ring)
            if let line = await line { page["daemon"] = ["title": line.title, "value": line.value] }
            if let machines = machines?() { page["machines"] = ["title": machines.title, "lines": machines.lines] as [String: Any] }
            guard let state = JSONValue(foundation: page) else {
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

    /// ``machinesStream``: one event per change of the row, until the page unsubscribes (the
    /// subscription's cancel ends the watch).
    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.machinesStream, let machines else { throw PageError.unknownOp(stream) }
        let read: @MainActor @Sendable () -> JSONValue = { Self.json(machines()) }
        // task-owner: the page's subscription; its cancel ends this loop
        let task = Task { @MainActor in
            var last = read()
            for await value in ObservationStream(read) where value != last {
                last = value
                onEvent(value)
            }
        }
        return PageSubscription { task.cancel() }
    }

    nonisolated static func json(_ machines: (title: String, lines: [String])?) -> JSONValue {
        guard let machines else { return .null }
        return .object(["title": .string(machines.title), "lines": .array(machines.lines.map { .string($0) })])
    }
}
