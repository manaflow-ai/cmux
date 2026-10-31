public import CmuxNextControl

#if DEBUG || CMUX_BENCH_HOOKS
/// A test seam (DEBUG and bench builds only; a release router drops every `debug.*` method): holds the daemon reply of
/// chosen pane and terminal creations (a split, New Column, New Row, a new terminal tab) until a test releases it, so a
/// journey makes the "first creation still pending while the person types and creates again" case in every round, on
/// any host and with no memory hog (P0 1193, cmux-ad 11:25Z). No product timing: a build without the debug methods has
/// no hold, and an armed hold that nobody releases ends after ``limit``.
///
/// One per daemon (``DaemonService/creationHold``); the app registers the local daemon's methods.
/// - `debug.creation.hold {"n": [1]}` (or `"n": 1`): from now on, the n-th creation that starts (1 = the next one,
///   counted in the order their keys ran) keeps its reply: the daemon made the pane, and the app applies it only at the
///   release. A creation that waits for an earlier one in its workspace (a second Cmd-D) waits for it as before.
///   Answers the armed numbers.
/// - `debug.creation.release {"n": 1}` lets creation n go on now (no `n`: every held one, and the hold is disarmed).
///   Answers which creations started, which are held now and which were released.
@MainActor
public final class DebugCreationHold {
    /// The creations a hold numbers (``DaemonService/intendNowReporting(_:_:transaction:_:)`` labels).
    static let creationLabels: Set<String> = ["split", "new-pane-right", "new-row", "new-tab"]
    /// The longest a held reply waits for its release.
    var limit: Duration = .seconds(30)

    private var armed: Set<Int> = []
    private var started = 0
    private var released: Set<Int> = []
    private var waiting: [Int: [CheckedContinuation<Void, Never>]] = [:]

    /// The number of a creation that starts now, when a hold is armed; nil otherwise.
    func creationStarted(_ label: String) -> Int? {
        guard !armed.isEmpty, Self.creationLabels.contains(label) else { return nil }
        started += 1
        return started
    }

    /// Waits until creation `number` is released when it is armed; returns at once otherwise.
    func replied(_ number: Int?) async {
        guard let number, armed.contains(number), !released.contains(number) else { return }
        let limit = limit
        // task-owner: the hold's own bound; a release first makes it a no-op.
        Task { @MainActor [weak self] in
            // wakeup-allow: a DEBUG test seam's one-shot bound, so a hold nobody releases never keeps a creation.
            try? await Task.sleep(for: limit)
            self?.release(number)
        }
        await withCheckedContinuation { waiting[number, default: []].append($0) }
    }

    func release(_ number: Int?) {
        let numbers = number.map { [$0] } ?? Array(armed)
        for number in numbers {
            released.insert(number)
            waiting.removeValue(forKey: number)?.forEach { $0.resume() }
        }
        if number == nil { armed = [] }
    }

    private var report: JSONValue {
        .object(["armed": .array(armed.sorted().map { .number(Double($0)) }), "started": .number(Double(started)),
                 "held": .array(waiting.keys.sorted().map { .number(Double($0)) }),
                 "released": .array(released.sorted().map { .number(Double($0)) })])
    }

    /// `debug.creation.hold` and `debug.creation.release`.
    public var methods: [ControlMethod] {
        [
            .mainActor("debug.creation.hold") { [self] call in
                let raw = call.params["n"]
                let numbers = raw?.arrayValue?.compactMap(\.intValue) ?? raw?.intValue.map { [$0] } ?? []
                guard !numbers.isEmpty, numbers.allSatisfy({ $0 > 0 }) else {
                    throw ControlError.invalidParams("debug.creation.hold: n is a creation number (1 = the next) or a list of them")
                }
                release(nil)
                armed = Set(numbers)
                started = 0
                released = []
                return .value(report)
            },
            .mainActor("debug.creation.release") { [self] call in
                release(call.params["n"]?.intValue)
                return .value(report)
            },
        ]
    }
}
#endif
