/// How one keyboard's physical keys become the keys an app receives, and
/// the reverse: which physical keys to press for a chord an agent expects.
///
/// Keys pass through Karabiner-Elements first (simple modifications, then
/// complex modifications, when Karabiner manages the keyboard), then macOS
/// (`hidutil`'s `UserKeyMapping`, then System Settings' modifier keys for
/// the keyboard that reaches macOS, which is Karabiner's virtual keyboard
/// for a keyboard Karabiner manages).
///
/// ```swift
/// let remap = PhysicalKeyRemap(karabiner: nil, system: HIDKeyMapping(destinations: [
///     .capsLock: .leftControl, .leftControl: .capsLock,
/// ]))
/// remap.resolve(agentKey: "ctrl+o") // press ⇪O; Caps Lock sends Control
/// ```
public struct PhysicalKeyRemap: Sendable {
    /// Karabiner-Elements' part, for one keyboard.
    struct KarabinerStage: Sendable {
        /// Simple modifications, the keyboard's own entries over the profile's.
        var simpleModifications: [PhysicalKey: KarabinerProfile.SimpleTarget]
        /// Manipulators whose conditions don't rule them out for this
        /// keyboard, in order, and whether their conditions surely hold.
        var manipulators: [(manipulator: KarabinerManipulator, certain: Bool)]

        func simpleTarget(_ key: PhysicalKey) -> KarabinerProfile.SimpleTarget {
            simpleModifications[key] ?? .key(key)
        }

        /// The first manipulator that takes `key`; Karabiner stops there.
        func complexMatch(key: PhysicalKey, held: [PhysicalKey]) -> KarabinerManipulator.Match {
            for (manipulator, certain) in manipulators {
                let match = manipulator.match(key: key, held: held)
                switch match {
                case .unmatched: continue
                case .unknown: return .unknown
                case .sends: return certain ? match : .unknown
                }
            }
            return .unmatched
        }
    }

    /// What pressing a physical chord does.
    enum Outcome: Equatable {
        /// The app receives this chord.
        case chord(LogicalKeyChord, viaKarabinerRule: Bool)
        /// Nothing that reads as a chord (a modifier turned into a letter).
        case nothing
        /// A rule cmux can't read is involved.
        case unknown
    }

    var karabiner: KarabinerStage?
    var system: HIDKeyMapping

    init(karabiner: KarabinerStage?, system: HIDKeyMapping) {
        self.karabiner = karabiner
        self.system = system
    }

    /// Which physical keys produce `agentKey` on this keyboard.
    ///
    /// Returns ``PhysicalKeyResolution/asPrinted`` when pressing the printed
    /// chord (with left-hand modifiers) works, when a rule cmux can't read
    /// is involved, when no physical chord produces it, when two different
    /// chords are equally good, or when the chord found shows the same
    /// glyphs as the printed one.
    ///
    /// - Parameter agentKey: A named key in `TerminalSurface.sendNamedKey`
    ///   form, such as `ctrl+o` or `escape`.
    public func resolve(agentKey: String) -> PhysicalKeyResolution {
        guard let target = LogicalKeyChord(agentKey: agentKey) else { return .asPrinted }
        switch press(target.asPrinted) {
        case .chord(target, _), .unknown: return .asPrinted
        default: break
        }
        // The best way to press each distinct set of glyphs.
        var byGlyphs: [String: (rank: [Int], press: PhysicalKeyPress)] = [:]
        for candidate in candidates(for: target) {
            guard case let .chord(produced, viaRule) = press(candidate), produced == target else { continue }
            let rank = [candidate.allKeys.count, candidate.modifiers.filter(\.isRightModifier).count, viaRule ? 1 : 0]
            if let existing = byGlyphs[candidate.glyphs], !rank.lexicographicallyPrecedes(existing.rank) { continue }
            byGlyphs[candidate.glyphs] = (
                rank,
                PhysicalKeyPress(chord: candidate, notes: notes(for: candidate), viaKarabinerRule: viaRule)
            )
        }
        guard let bestRank = byGlyphs.values.map(\.rank).min(by: { $0.lexicographicallyPrecedes($1) }) else {
            return .asPrinted
        }
        let best = byGlyphs.values.filter { $0.rank == bestRank }
        // Two different chords that are equally good: don't pick one.
        guard best.count == 1, let only = best.first else { return .asPrinted }
        // Right Control where left Control is remapped still reads as ⌃O.
        guard only.press.chord.glyphs != target.asPrinted.glyphs else { return .asPrinted }
        return .press(only.press)
    }

    /// What pressing `chord` sends to the app.
    func press(_ chord: PhysicalKeyChord) -> Outcome {
        var held: [PhysicalKey] = []
        var base = chord.key
        var viaRule = false
        if let karabiner {
            for modifier in chord.modifiers {
                guard case let .key(key) = karabiner.simpleTarget(modifier) else { return .unknown }
                if key == .noAction { continue }
                guard key.isHoldable else { return .nothing }
                switch karabiner.complexMatch(key: key, held: held) {
                case .unmatched:
                    held.append(key)
                case .unknown:
                    return .unknown
                case let .sends(sent, stillHeld):
                    guard sent.isHoldable else { return .nothing }
                    held = stillHeld + [sent]
                    viaRule = true
                }
            }
            guard case let .key(key) = karabiner.simpleTarget(chord.key) else { return .unknown }
            guard key != .noAction else { return .nothing }
            switch karabiner.complexMatch(key: key, held: held) {
            case .unmatched:
                base = key
            case .unknown:
                return .unknown
            case let .sends(sent, stillHeld):
                base = sent
                held = stillHeld
                viaRule = true
            }
        } else {
            held = chord.modifiers
        }
        var modifiers = Set<KeyboardModifier>()
        for key in held {
            let output = system.output(for: key)
            if output == .noAction { continue }
            guard let modifier = output.modifier else { return .nothing }
            modifiers.insert(modifier)
        }
        let key = system.output(for: base)
        guard key != .noAction, key.modifier == nil else { return .nothing }
        return .chord(LogicalKeyChord(modifiers: modifiers, key: key), viaKarabinerRule: viaRule)
    }

    /// The key a physical key becomes on its own, through simple
    /// modifications and macOS; `nil` when a simple modification cmux can't
    /// read takes it.
    private func alone(_ key: PhysicalKey) -> PhysicalKey? {
        guard let simple = afterSimple(key) else { return nil }
        return system.output(for: simple)
    }

    private func afterSimple(_ key: PhysicalKey) -> PhysicalKey? {
        guard let karabiner else { return key }
        guard case let .key(output) = karabiner.simpleTarget(key) else { return nil }
        return output
    }

    /// Physical keys whose simple modification sends `key`.
    private func simplePreimage(_ key: PhysicalKey) -> [PhysicalKey] {
        PhysicalKey.allNamed.filter { afterSimple($0) == key }
    }

    /// Chords worth checking for `target`: keys that become the wanted
    /// keys on their own, and the inputs of plain complex modifications
    /// that send the wanted chord.
    private func candidates(for target: LogicalKeyChord) -> [PhysicalKeyChord] {
        let modifiers = KeyboardModifier.allCases.filter(target.modifiers.contains)
        var alone: [(key: PhysicalKey, output: PhysicalKey)] = []
        for key in PhysicalKey.allNamed {
            if let output = self.alone(key) { alone.append((key, output)) }
        }
        let bases = alone.filter { $0.output == target.key }.map(\.key)
        let modifierChoices = modifiers.map { modifier in alone.filter { $0.output.modifier == modifier }.map(\.key) }
        var candidates = Self.combinations(modifierChoices).flatMap { held in
            bases.map { PhysicalKeyChord(modifiers: held, key: $0) }
        }
        guard let karabiner else { return candidates }
        for (manipulator, certain) in karabiner.manipulators where certain {
            guard case let .key(from, mandatory, optional) = manipulator.from,
                  case let .key(sent, sentModifiers) = manipulator.output,
                  system.output(for: sent) == target.key else { continue }
            let produced = Set(sentModifiers.compactMap { system.output(for: $0).modifier })
            guard produced.isSubset(of: target.modifiers) else { continue }
            // Modifiers the rule doesn't send must be held through it as optional ones.
            let missing = modifiers.filter { !produced.contains($0) }
            var choices = mandatory.map { requirement in
                requirement.satisfyingKeys.flatMap(simplePreimage)
            }
            for modifier in missing {
                choices.append(alone.filter { entry in
                    entry.output.modifier == modifier
                        && afterSimple(entry.key).map { key in optional.contains { $0.isSatisfied(by: key) } } == true
                }.map(\.key))
            }
            let keys = simplePreimage(from)
            for held in Self.combinations(choices) {
                candidates += keys.map { PhysicalKeyChord(modifiers: held, key: $0) }
            }
        }
        return candidates
    }

    /// Keys in `chord` that send another key on their own.
    private func notes(for chord: PhysicalKeyChord) -> [PhysicalKeyNote] {
        chord.allKeys.compactMap { key in
            guard let output = alone(key), output != key else { return nil }
            if let modifier = key.modifier, output.modifier == modifier { return nil }
            return PhysicalKeyNote(physical: key, sends: output)
        }
    }

    /// Every way to pick one key from each list, capped so a pathological
    /// config can't make hover slow.
    private static func combinations(_ choices: [[PhysicalKey]]) -> [[PhysicalKey]] {
        var result: [[PhysicalKey]] = [[]]
        for options in choices {
            var next: [[PhysicalKey]] = []
            for prefix in result {
                for option in options where !prefix.contains(option) {
                    next.append(prefix + [option])
                    if next.count >= 64 { break }
                }
                if next.count >= 64 { break }
            }
            result = next
        }
        return result
    }
}
