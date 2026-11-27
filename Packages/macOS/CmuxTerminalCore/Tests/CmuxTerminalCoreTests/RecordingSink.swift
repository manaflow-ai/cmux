import CmuxTerminalCore

/// In-memory ``BackgroundLogLineSink`` for deterministic tests: it records lines
/// and lets a test `await` a target count (or a marker line) via continuations —
/// no temp files, no `Task.sleep`, no polling. An optional gate holds the writer's
/// consumer so a burst can overflow the bounded buffer on purpose.
actor RecordingSink: BackgroundLogLineSink {
    private(set) var lines: [String] = []
    private let gated: Bool
    private var gateOpen: Bool
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(target: Int, continuation: CheckedContinuation<[String], Never>)] = []
    private var markerWaiters: [(marker: String, continuation: CheckedContinuation<[String], Never>)] = []

    init(gated: Bool = false) {
        self.gated = gated
        self.gateOpen = !gated
    }

    func openGate() {
        gateOpen = true
        let waiters = gateWaiters
        gateWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func write(_ line: String) async {
        if !gateOpen {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gateWaiters.append(continuation)
            }
        }
        lines.append(line)
        let snapshot = lines
        countWaiters.removeAll { waiter in
            guard snapshot.count >= waiter.target else { return false }
            waiter.continuation.resume(returning: snapshot)
            return true
        }
        markerWaiters.removeAll { waiter in
            guard line.contains(waiter.marker) else { return false }
            waiter.continuation.resume(returning: snapshot)
            return true
        }
    }

    func waitForLines(_ count: Int) async -> [String] {
        if lines.count >= count {
            return lines
        }
        return await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func waitForLineContaining(_ marker: String) async -> [String] {
        if lines.contains(where: { $0.contains(marker) }) {
            return lines
        }
        return await withCheckedContinuation { continuation in
            markerWaiters.append((marker, continuation))
        }
    }
}
