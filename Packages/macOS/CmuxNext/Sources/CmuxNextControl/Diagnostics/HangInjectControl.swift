#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextSettings
public import CmuxNextTrace

/// `debug.hang_inject` (Debug and bench builds, p09-observability-088): hangs one watched lane of the app on
/// purpose, for scripts/cmux-next/hang-matrix.py (done check 7). Chrome hangs a target thread the same way for its
/// own checks (`chrome://uithreadhang`, content/browser/renderer_host/debug_urls.cc).
///
/// - `{"lane": "<registered name>", "ms": 3000}` arms the lane: its next hang-watch scope keeps its thread busy
///   for `ms` inside the scope (``HangWatch/armHang(lane:busyFor:)``), so the monitor reports it once, with that
///   thread's stack (`debug.hangs` `thread_hangs`). One lane is armed at a time.
/// - `{"lane": "main", "ms": 5000}` keeps the main thread busy for `ms` now, in this request's main-actor turn:
///   the main-thread watchdog's stall, and with a kill during it, the fatal-hang report at the next launch.
/// - `{"action": "disarm"}` disarms; `{"action": "list"}` arms nothing.
///
/// Every answer lists the registered lane names, the armed one and the longest hang an arm may ask for. The method
/// takes no path and no command; Release builds do not compile it.
public struct HangInjectControl: Sendable {
    /// The lane name that hangs the main thread itself.
    public static let mainLane = "main"
    /// The hang when the request names no `ms` (done check 7: 3 s).
    static let defaultHang: Duration = .seconds(3)

    private let watch: HangWatch

    /// Makes the method over the process's hang watch (`TraceRuntime.shared.hangWatch` at the composition root).
    public init(watch: HangWatch) {
        self.watch = watch
    }

    /// The `debug.hang_inject` control method.
    public var method: ControlMethod {
        .mainActor("debug.hang_inject") { [watch] call in
            let request = try Self.request(call.params)
            return .value(try Self.run(request, on: watch))
        }.withDeadline(.fixed(HangWatch.maxInjectedHang + .seconds(2)))
    }

    /// What a request asks for.
    enum Request: Equatable {
        case arm(lane: String, hang: Duration)
        case hangMain(Duration)
        case disarm
        case list
    }

    static func request(_ params: [String: JSONValue]) throws -> Request {
        let known: Set<String> = ["action", "lane", "ms"]
        if let unknown = params.keys.first(where: { !known.contains($0) }) {
            throw ControlError.invalidParams("debug.hang_inject: unknown input \(unknown); give lane and ms, or action")
        }
        let hang: Duration
        if let ms = params["ms"] {
            guard let whole = ms.intValue, whole > 0, Duration.milliseconds(whole) <= HangWatch.maxInjectedHang else {
                throw ControlError.invalidParams("debug.hang_inject: ms must be a whole number from 1 to 30000")
            }
            hang = .milliseconds(whole)
        } else {
            hang = defaultHang
        }
        let lane = params["lane"]?.stringValue
        switch params["action"]?.stringValue ?? "arm" {
        case "arm":
            guard let lane else { throw ControlError.invalidParams("debug.hang_inject: lane is required") }
            return lane == mainLane ? .hangMain(hang) : .arm(lane: lane, hang: hang)
        case "disarm" where lane == nil: return .disarm
        case "list" where lane == nil: return .list
        default: throw ControlError.invalidParams("debug.hang_inject: action must be arm (with lane), disarm or list")
        }
    }

    @MainActor
    static func run(_ request: Request, on watch: HangWatch) throws -> JSONValue {
        var reply: [String: JSONValue] = [:]
        switch request {
        case .arm(let lane, let hang):
            do throws(HangWatch.HangInjectError) {
                try watch.armHang(lane: lane, busyFor: hang)
            } catch {
                switch error {
                case .unknownLane(let name):
                    throw ControlError.invalidParams("debug.hang_inject: no registered lane \(name)",
                                                     data: ["lanes": .array(watch.registeredNames.map(JSONValue.string))])
                case .alreadyArmed(let armed):
                    throw ControlError.invalidParams("debug.hang_inject: \(armed) is armed already; disarm it first")
                case .badDuration:
                    throw ControlError.invalidParams("debug.hang_inject: ms must be a whole number from 1 to 30000")
                }
            }
            reply["armed_lane"] = .string(lane)
            reply["ms"] = JSONValue(hang.wholeMilliseconds)
        case .hangMain(let hang):
            let end = watch.nowNanos() &+ UInt64(clamping: hang.wholeMilliseconds) &* 1_000_000
            // The injected main-thread hang itself: the main thread stays busy in this turn.
            while watch.nowNanos() < end {}
            reply["hung_main_ms"] = JSONValue(hang.wholeMilliseconds)
        case .disarm:
            reply["disarmed"] = watch.disarmHang().map(JSONValue.string) ?? .null
        case .list:
            break
        }
        reply["armed"] = watch.armedHang.map(JSONValue.string) ?? .null
        reply["lanes"] = .array(([Self.mainLane] + watch.registeredNames).map(JSONValue.string))
        reply["max_ms"] = JSONValue(HangWatch.maxInjectedHang.wholeMilliseconds)
        return .object(reply)
    }
}
#endif
