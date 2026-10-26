public import CmuxNextWakeups

/// The control service's launch order (p08-startup-019, plans/cmux-next/chrome-parity/p08-startup.md 3A).
///
/// `main()` binds the socket on a lane after the owner check (``ControlSocketBind``). After the first
/// frame, as ``StartupPriority/afterFirstFrame`` posts budgeted behind input: the service's start, then
/// one post per method group, then the start of accepting. No request is read before every group is
/// registered, so none gets `method_not_found` for a method that is still to come; a client that
/// connected early waits in the backlog. Requests run at ``MainWorkClass/automation``.
///
/// This replaces waiting for the launch to settle (cx-z9kz0, d08d8d7d3c5): the first page's main-thread
/// turns now come first by class (visible and input before automation), not by a timer.
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
    ///   - socket: The socket `main()` bound off main; nil: the service binds when it serves.
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
}
