/// How a key sequence resolves against the table (R59 chords, K2): the
/// semantics every client shares (the Mac key router's `ChordTracker`, the
/// GPUI and browser clients) and that `keybinding-vectors.json` pins.
///
/// At each key, a key that leads to a longer entry whose action can run
/// arms (extends) the chord, and wins over an entry that the same key
/// completes; else the key completes the entry that wins for the whole
/// sequence; else nothing. The Cmd-J leader arms as a first key whenever
/// any entry sits under it, even one that cannot run in this context, so
/// its overlay can say what it offers. A key has several readings
/// (`ActionRegistry.shortcuts(for:)`: its characters, then the unshifted
/// key); the first reading that extends wins, then the first that completes.
extension KeyBindingTable {
    public enum SequenceStep: Hashable, Sendable {
        /// The key completes this entry.
        case run(KeyBinding)
        /// The key arms or extends the chord with this reading.
        case extend(Shortcut)
        case none
    }

    /// The step a key with `readings` takes after the armed `keys` (empty
    /// for a first key).
    public func step(after keys: [Shortcut], readings: [Shortcut], in context: KeyContext,
                     isRunnable: (ActionID) -> Bool) -> SequenceStep {
        if keys.count + 1 < Self.maxSequenceLength,
           let longer = readings.first(where: { continues(keys + [$0], in: context, isRunnable: isRunnable) }) {
            return .extend(longer)
        }
        if keys.isEmpty, readings.contains(LeaderLayer.prefix), !entries(after: [LeaderLayer.prefix]).isEmpty {
            return .extend(LeaderLayer.prefix)
        }
        for reading in readings {
            if let winner = resolve(keys + [reading], in: context, isRunnable: isRunnable).winner { return .run(winner) }
        }
        return .none
    }

    /// Where a whole sequence ends: an entry runs, the chord stays armed
    /// with these keys, or nothing (a key that completed nothing).
    public enum SequenceOutcome: Hashable, Sendable {
        case run(KeyBinding)
        case armed([Shortcut])
        case none
    }

    /// Resolves `sequence`, one array of readings per key.
    public func outcome(of sequence: [[Shortcut]], in context: KeyContext, isRunnable: (ActionID) -> Bool) -> SequenceOutcome {
        var keys: [Shortcut] = []
        for (offset, readings) in sequence.enumerated() {
            switch step(after: keys, readings: readings, in: context, isRunnable: isRunnable) {
            case .run(let binding):
                return offset == sequence.count - 1 ? .run(binding) : .none
            case .extend(let key):
                keys.append(key)
            case .none:
                return .none
            }
        }
        return keys.isEmpty ? .none : .armed(keys)
    }
}
