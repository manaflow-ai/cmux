public import CmuxNextWakeups

/// The control service's launch order (plans/cmux-next/chrome-parity/p08-startup.md 3A).
///
/// With the feature `controlSocketEarlyBind` (``post(on:socket:start:groups:served:)``): the socket is
/// bound on a lane after the owner check (``ControlSocketBind``). After the first frame (or the
/// launch's ``StartupScheduler/firstFrameMissed(_:)``), as ``StartupPriority/afterFirstFrame`` posts
/// budgeted behind input: the service's start, then one post per method group, then the start of
/// accepting. No request is read before every group is registered, so none gets `method_not_found`
/// for a method that is still to come; a client that connected early waits in the backlog. Requests
/// run at ``MainWorkClass/automation``.
///
/// Without it (``run(start:groups:served:)``): the caller waits for the launch to settle (cx-z9kz0,
/// d08d8d7d3c5), then the service starts, every group registers and the service binds, in one turn.
///
/// ```swift
/// ControlLaunch.post(on: order.startup, socket: controlSocket,
///                    start: { try ControlService.prepare(...) },
///                    groups: [.init("Control.registerCloudMethods") { router in ... }],
///                    served: { result in logger.info("control socket \(result)") })
/// ```
@MainActor
public final class ControlLaunch {
    /// A method group: its startup task name (`Control.<step>`) and its registration on the router.
    public struct Group: Sendable {
        let name: StaticString
        let register: @MainActor @Sendable (ControlRouter) -> Void

        public init(_ name: StaticString, _ register: @escaping @MainActor @Sendable (ControlRouter) -> Void) {
            self.name = name
            self.register = register
        }
    }

    private let socket: ControlSocketBind?
    private var service: ControlService?

    private init(socket: ControlSocketBind?) {
        self.socket = socket
    }

    /// Posts the launch.
    ///
    /// - Parameters:
    ///   - startup: The launch's scheduler.
    ///   - socket: The socket bound on a lane; nil: the service binds when it serves.
    ///   - start: Builds the service with its core methods (nil: the app is going, nothing to serve).
    ///     A throw (the resolved access mode is `off`) discards the socket.
    ///   - groups: The method groups, one post each, in order.
    ///   - served: Called once: with the socket's path when it accepts, or with why it does not.
    public static func post(on startup: StartupScheduler, socket: ControlSocketBind?,
                            start: @escaping @MainActor @Sendable () throws -> ControlService?, groups: [Group],
                            served: @escaping @MainActor @Sendable (Result<String, any Error>) -> Void) {
        let launch = ControlLaunch(socket: socket)
        startup.post(.afterFirstFrame, "Control.start", on: .main) {
            do {
                launch.service = try start()
            } catch {
                socket?.discard()
                served(.failure(error))
            }
        }
        for group in groups {
            startup.post(.afterFirstFrame, group.name, on: .main) {
                guard let router = launch.service?.router else { return }
                group.register(router)
            }
        }
        startup.post(.afterFirstFrame, "Control.serve", on: .main) {
            launch.service?.serve(after: launch.socket, served)
        }
    }

    /// Releases `startup`'s afterFirstFrame posts at `phase`'s reveal when the reveal was not the first
    /// frame: a hidden or windowless launch, or a first frame past the reveal deadline (1.5 s). So a
    /// launch that never draws (no window, no GUI session) serves at its reveal, not at the 10 s
    /// failsafe. The first-frame ref stays held for a late frame or the failsafe
    /// (``StartupScheduler/firstFrameMissed(_:)`` with nil).
    public static func releaseAtReveal(phase: StartupPhase, startup: StartupScheduler) {
        phase.whenReached(.revealed) { [weak phase, weak startup] in
            guard phase?.revealCause != .firstFrame else { return }
            startup?.firstFrameMissed(nil)
        }
    }

    /// Starts the service, registers every group and binds, now and in this turn (the launch order
    /// without `controlSocketEarlyBind`).
    ///
    /// - Parameters:
    ///   - start: Builds the service with its core methods (nil: the app is going, nothing to serve).
    ///   - groups: The method groups, in order.
    ///   - served: Called once unless `start` gives nil: with the socket's path, or with why it does not serve.
    public static func run(start: @MainActor () throws -> ControlService?, groups: [Group],
                           served: @MainActor (Result<String, any Error>) -> Void) {
        let service: ControlService?
        do {
            service = try start()
        } catch {
            return served(.failure(error))
        }
        guard let service else { return }
        for group in groups { group.register(service.router) }
        do {
            try service.serve(adopting: nil)
            served(.success(service.socketPath))
        } catch {
            served(.failure(error))
        }
    }
}
