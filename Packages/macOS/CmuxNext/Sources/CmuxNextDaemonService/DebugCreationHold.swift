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
/// - `"stand_in": [2]` (with or without `n`) also keeps creation 2's stand-in (its pane or tab shown before the reply)
///   out of the store until its release, and holds its reply too. Its focus is asked for in its key's turn, as always,
///   and cannot land meanwhile: the state of a window whose main thread ran the next keys before it laid the new pane
///   out (TIP RED 1193 under memory pressure), made on purpose. Its release shows the stand-in first.
/// - `debug.creation.release {"n": 1}` lets creation n go on now (no `n`: every held one, and the hold is disarmed).
///   Answers which creations started, which are held now, which were released, and `resumed`: the creations whose
///   waiting reply this call let go (a creation in `released` but not in `resumed` never waited), and `shown`: the
///   creations whose held stand-in this call put in the store.
@MainActor
public final class DebugCreationHold {
    /// The creations a hold numbers (``DaemonService/intendNowReporting(_:_:transaction:_:)`` labels).
    static let creationLabels: Set<String> = ["split", "new-pane-right", "new-row", "new-tab"]
    /// The longest a held reply waits for its release.
    var limit: Duration = .seconds(30)

    private var armed: Set<Int> = []
    private var standIns: Set<Int> = []
    /// Held stand-ins, by creation: each puts its intent in the store.
    private var shownLater: [Int: @MainActor () -> Void] = [:]
    private var started = 0
    private var released: Set<Int> = []
    private var waiting: [Int: [CheckedContinuation<Void, Never>]] = [:]

    /// The number of a creation that starts now, when a hold is armed; nil otherwise.
    func creationStarted(_ label: String) -> Int? {
        guard !(armed.isEmpty && standIns.isEmpty), Self.creationLabels.contains(label) else { return nil }
        started += 1
        return started
    }

    /// Puts creation `number`'s stand-in in the store (`show`) now, or at its release when its stand-in is held.
    func intend(_ number: Int?, _ show: @escaping @MainActor () -> Void) {
        guard let number, standIns.contains(number), !released.contains(number) else { return show() }
        shownLater[number] = show
        bound(number)
    }

    /// Waits until creation `number` is released when its reply or stand-in is held; returns at once otherwise.
    func replied(_ number: Int?) async {
        guard let number, armed.contains(number) || standIns.contains(number), !released.contains(number) else { return }
        bound(number)
        await withCheckedContinuation { waiting[number, default: []].append($0) }
    }

    /// Releases `number` after ``limit`` unless a test released it first.
    private func bound(_ number: Int) {
        let limit = limit
        // task-owner: the hold's own bound; a release first makes it a no-op.
        Task { @MainActor [weak self] in
            // wakeup-allow: a DEBUG test seam's one-shot bound, so a hold nobody releases never keeps a creation.
            try? await Task.sleep(for: limit)
            self?.release(number)
        }
    }

    /// Lets creation `number` go on (nil: every armed one, and the hold is disarmed). Returns the numbers whose waiting
    /// creation this call resumed: proof that the creation really waited for this release.
    @discardableResult
    func release(_ number: Int?) -> (resumed: [Int], shown: [Int]) {
        let numbers = number.map { [$0] } ?? Array(armed.union(standIns)).sorted()
        var resumed: [Int] = [], shown: [Int] = []
        // Stand-ins first: a creation's reply applies on top of its stand-in.
        for number in numbers {
            guard let show = shownLater.removeValue(forKey: number) else { continue }
            show()
            shown.append(number)
        }
        for number in numbers {
            released.insert(number)
            guard let continuations = waiting.removeValue(forKey: number) else { continue }
            continuations.forEach { $0.resume() }
            resumed.append(number)
        }
        if number == nil {
            armed = []
            standIns = []
        }
        return (resumed.sorted(), shown.sorted())
    }

    /// The hold's state, in the control socket's own JSON type, taken from `call`'s params (CmuxNextDaemon has a
    /// `JSONValue` too), one key per line, as `debug.daemon` builds its reply.
    private func reply(_ call: ControlCall, resumed: [Int] = [], shown: [Int] = []) -> ControlReply {
        var report = call.params.filter { _ in false }
        report["resumed"] = .array(resumed.map { .number(Double($0)) })
        report["shown"] = .array(shown.map { .number(Double($0)) })
        report["stand_in"] = .array(standIns.sorted().map { .number(Double($0)) })
        report["armed"] = .array(armed.sorted().map { .number(Double($0)) })
        report["started"] = .number(Double(started))
        report["held"] = .array(waiting.keys.sorted().map { .number(Double($0)) })
        report["released"] = .array(released.sorted().map { .number(Double($0)) })
        return .value(.object(report))
    }

    /// `debug.creation.hold` and `debug.creation.release`.
    public var methods: [ControlMethod] {
        [
            .mainActor("debug.creation.hold") { [self] call in
                // A creation number or a list of them; empty when absent.
                func creationNumbers(_ key: String) -> [Int] {
                    let raw = call.params[key]
                    if let one = raw?.intValue { return [one] }
                    return raw?.arrayValue?.compactMap(\.intValue) ?? []
                }
                let numbers = creationNumbers("n"), standIns = creationNumbers("stand_in")
                guard !(numbers.isEmpty && standIns.isEmpty), (numbers + standIns).allSatisfy({ $0 > 0 }) else {
                    throw ControlError.invalidParams("debug.creation.hold: n and stand_in are creation numbers (1 = the next) or lists of them")
                }
                release(nil)
                armed = Set(numbers)
                self.standIns = Set(standIns)
                started = 0
                released = []
                return reply(call)
            },
            .mainActor("debug.creation.release") { [self] call in
                let (resumed, shown) = release(call.params["n"]?.intValue)
                return reply(call, resumed: resumed, shown: shown)
            },
        ]
    }
}
#endif
