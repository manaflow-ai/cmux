/// How a key sequence resolves against the table (R59 chords, K2): the
/// semantics every client shares (the Mac key router's `ChordTracker`, the
/// GPUI and browser clients) and that `keybinding-vectors.json` pins.
///
/// At each key, a key that leads to a longer entry whose action can run
/// arms (extends) the chord, and wins over an entry that the same key
/// completes; else the key completes the entry that wins for the whole
/// sequence; else nothing. The Cmd-J leader arms as a first key whenever
/// any entry sits under it, even one that cannot run in this context, so
/// its overlay can say what it offers. A bare first key (no Command,
/// Control or Option: `g g`) arms only where the context owns bare keys
/// (``KeyContext/ownsBareKeys``, K1). A key has several readings
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
    public func step(after keys: [Shortcut], readings: some Collection<Shortcut>, in context: KeyContext, // perf-hot: 0.5ms key-dispatch (every chord key-down)
                     isRunnable: (ActionID) -> Bool) -> SequenceStep {
        // A bare sequence goes on only while the context still owns bare
        // keys: focus that moved into a text field mid-sequence types the key.
        if let first = keys.first, first.isBare, !context.ownsBareKeys { return .none }
        let input = CompiledWhen.Input(context)
        if keys.count + 1 < Self.maxSequenceLength,
           let longer = readings.first(where: {
               (!keys.isEmpty || !$0.isBare || context.ownsBareKeys)
                   && continues(KeysThenOne(keys, $0), in: input, isRunnable: isRunnable)
           }) {
            return .extend(longer)
        }
        if keys.isEmpty, readings.contains(LeaderLayer.prefix), hasEntries(after: CollectionOfOne(LeaderLayer.prefix)) {
            return .extend(LeaderLayer.prefix)
        }
        for reading in readings {
            if let winner = resolveWinner(KeysThenOne(keys, reading), in: input, isRunnable: isRunnable) { return .run(winner) }
        }
        return .none
    }

    /// The armed keys followed by one more key, read in place: the sequence a reading would make,
    /// with no array built for it, so a chord key-down allocates nothing in ``step(after:readings:in:isRunnable:)``.
    public nonisolated struct KeysThenOne: RandomAccessCollection, Sendable {
        public let keys: [Shortcut]
        public let next: Shortcut

        public init(_ keys: [Shortcut], _ next: Shortcut) {
            self.keys = keys
            self.next = next
        }

        public var startIndex: Int { 0 }
        public var endIndex: Int { keys.count + 1 }

        public subscript(position: Int) -> Shortcut {
            position == keys.count ? next : keys[position]
        }
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
