public import CmuxNextInputCore

/// The key slots in dispatch, innermost on top (``InputLatencyTracker/dispatchingKey``): a held key run again inside
/// another key's dispatch is the dispatching key until its own dispatch ends, then the outer one is again. Four inline
/// entries and no heap storage, so the per-key path allocates nothing; a nesting deeper than four keeps the innermost
/// four (a dispatch never nests that deep: a replay runs inside one key).
struct DispatchingKeys {
    private var entries: (InputLatencyToken?, InputLatencyToken?, InputLatencyToken?, InputLatencyToken?) = (nil, nil, nil, nil)
    private(set) var count = 0

    /// The innermost key in dispatch.
    var top: InputLatencyToken? { count == 0 ? nil : self[count - 1] }

    private subscript(index: Int) -> InputLatencyToken? {
        get {
            switch index {
            case 0: entries.0
            case 1: entries.1
            case 2: entries.2
            default: entries.3
            }
        }
        set {
            switch index {
            case 0: entries.0 = newValue
            case 1: entries.1 = newValue
            case 2: entries.2 = newValue
            default: entries.3 = newValue
            }
        }
    }

    // perf-hot: 0.05us key-dispatch
    mutating func push(_ token: InputLatencyToken) {
        if count == 4 {
            // Deeper than four: the outermost goes.
            for index in 0..<3 { self[index] = self[index + 1] }
            count = 3
        }
        self[count] = token
        count += 1
    }

    /// Removes `token` wherever it is (its dispatch ended, or its slot was dropped).
    // perf-hot: 0.05us key-dispatch
    mutating func remove(_ token: InputLatencyToken) {
        var index = count - 1
        while index >= 0, self[index] != token { index -= 1 }
        guard index >= 0 else { return }
        var next = index
        while next < count - 1 {
            self[next] = self[next + 1]
            next += 1
        }
        self[count - 1] = nil
        count -= 1
    }
}
