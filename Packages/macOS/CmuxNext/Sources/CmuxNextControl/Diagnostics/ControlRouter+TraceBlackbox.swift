public import CmuxNextCompat
public import CmuxNextSettings

/// `trace.blackbox` (plans/cmux-next/chrome-parity/p09-observability.md task 125), which `cmux trace blackbox`
/// exports to Perfetto:
///
/// - `{now: true}` (or no parameter): every live process's black box copied now into a new folder of `blackbox-now`
///   (``LastHangBundles/captureNow(_:)``), on BackgroundWork `.files`.
/// - `{last_hang: N}`: the bundle copied at the N-th newest hang (1 to ``LastHangBundles/kept``), with the cause
///   its manifest names.
///
/// The reply is `{bundle, now}` or `{bundle, last_hang, cause}`: `bundle` is a folder with the `manifest.json`
/// of a `cmux trace record` bundle. No parameter names a file, as Chrome's tracing service takes none from a
/// consumer (services/tracing/perfetto/consumer_host.cc): the app picks every path. A caller that acts for a
/// remote relay (`origin: "remote"`) or for a cmux app is refused before anything runs, since the bundle holds
/// local timing (skills/cmux-socket-policy/references/remote-relay-authorization.md: no relay allowlists it),
/// and an unknown parameter is refused rather than ignored.
///
/// ```swift
/// router.register(TraceBlackboxControl(bundles: bundles, work: work).methods)
/// ```
public struct TraceBlackboxControl: Sendable {
    /// The method's deadline: a copy of every black box takes well under a second; a busy files lane waits.
    public static let deadline: Duration = .seconds(25)

    private let bundles: LastHangBundles
    private let work: any MayBlockRunner

    /// The method over `bundles`, copying on `work`'s `.files` lane.
    public init(bundles: LastHangBundles, work: any MayBlockRunner) {
        self.bundles = bundles
        self.work = work
    }

    /// `trace.blackbox` over `bundles`, none when there are none (a process with no black box).
    public static func methods(_ bundles: LastHangBundles?, work: any MayBlockRunner) -> [ControlMethod] {
        bundles.map { TraceBlackboxControl(bundles: $0, work: work).methods } ?? []
    }

    /// `trace.blackbox`, for ``ControlRouter/register(_:)``.
    public var methods: [ControlMethod] {
        [.async("trace.blackbox") { [self] call in try await reply(call) }.withDeadline(.fixed(Self.deadline))]
    }

    func reply(_ call: ControlCall) async throws -> JSONValue {
        try Self.admit(call)
        let bundles = bundles
        switch try Request(call.params) {
        case .now:
            let path = try await work.runFiles(.userBlocking) { permit in bundles.captureNow(permit) }
            guard let path else {
                throw ControlError(code: "blackbox_failed",
                                   message: ControlStrings.format("control.error.traceBlackboxFailed",
                                                                  "the black boxes could not be copied into %@", bundles.nowDirectory))
            }
            return ["bundle": .string(path), "now": true]
        case .lastHang(let n):
            let found = try await work.runFiles(.userBlocking) { permit in bundles.bundle(n, permit) }
            guard let found else {
                throw bundles.capturesHangs
                    ? ControlError(code: "no_last_hang",
                                   message: ControlStrings.format("control.error.traceNoLastHang",
                                                                  "there is no last-hang bundle %@: cmux copies one at a hang of 1 s or more or a key frame over 50 ms",
                                                                  String(n)))
                    : ControlError(code: "last_hang_off",
                                   message: ControlStrings.text("control.error.traceLastHangOff",
                                                                "this build makes no last-hang bundles: the lastHangBundle feature is off"))
            }
            return ["bundle": .string(found.path), "last_hang": JSONValue(n), "cause": found.cause]
        }
    }

    /// What a call asks for.
    enum Request: Equatable {
        case now
        case lastHang(Int)

        /// `now` and `last_hang`, checked: one of them, `last_hang` from 1 to ``LastHangBundles/kept``.
        init(_ params: [String: JSONValue]) throws {
            let now: Bool
            switch params["now"] {
            case nil, .null?: now = false
            case .bool(let flag)?: now = flag
            case _?: throw ControlError.invalidParams(ControlStrings.format("control.error.boolShape", "%@ must be true or false", "now"))
            }
            switch params["last_hang"] {
            case nil, .null?:
                self = .now
            case let value?:
                guard !now else {
                    throw ControlError.invalidParams(ControlStrings.text("control.error.traceBlackboxSource",
                                                                         "trace.blackbox takes last_hang or now, not both"))
                }
                guard let n = value.intValue, (1 ... LastHangBundles.kept).contains(n) else {
                    throw ControlError.invalidParams(ControlStrings.format("control.error.traceLastHangRange",
                                                                           "last_hang must be a whole number from 1 to %@",
                                                                           String(LastHangBundles.kept)))
                }
                self = .lastHang(n)
            }
        }
    }

    /// Every parameter `trace.blackbox` reads, and the router's own on any request.
    static let parameters: Set<String> = ["now", "last_hang", "origin", "caller", "after"]

    /// Refuses a relay or app caller, then any parameter outside ``parameters``.
    static func admit(_ call: ControlCall) throws {
        let origin = try ControlOrigin().validated(call.params["origin"], connection: call.connection)
        guard origin != "remote", call.request.callerApp == nil else {
            throw ControlError(code: "forbidden",
                               message: ControlStrings.format("control.error.traceBlackboxLocal",
                                                              "%@ serves local callers only, never a remote relay or a cmux app", call.method))
        }
        for name in call.params.keys.sorted() where !parameters.contains(name) {
            throw ControlError.invalidParams(ControlStrings.format("control.error.unknownParam", "%1$@ does not take params.%2$@", call.method, name),
                                             data: ["param": .string(name)])
        }
    }
}
