import AppKit
import Carbon.HIToolbox
@testable import CmuxNextActions
import Testing

/// T1 of the input model (input-languages.md): a key as ``KeyInput`` reads it resolves to the same
/// action on every keyboard layout, in Ghostty's match order (ghostty-next src/input/Binding.zig
/// `Set.getEvent`, its tests "set: getEvent physical / codepoint / codepoint case folding"):
/// the physical key where the binding is physical (the digit row: Ghostty binds `goto_tab` to
/// both `digit_N` and `N`, because AZERTY types `&` `é` `"` there), then the text the key
/// types, then the unshifted key, and last, for a Command or Control chord on a layout that types
/// no ASCII on the key, the ASCII-capable layout's key (Chrome's and AppKit's fallback).
///
/// The layouts are fixtures (what macOS's layouts type, by virtual key code), so the test needs
/// no keyboard and no selected input source; the fleet sweep (T2) reads every installed layout.
@MainActor @Suite struct KeyInputLayoutTests {
    // MARK: Layout fixtures

    /// One keyboard layout: what each physical key types unshifted and shifted, and with Command
    /// held where the layout has a Command key map (non-Latin layouts and Dvorak - QWERTY ⌘ type
    /// QWERTY Latin letters with Command).
    nonisolated struct Layout: Sendable, CustomTestStringConvertible {
        let name: String
        let keys: [UInt16: Pair]
        let command: [UInt16: Pair]
        /// Types ASCII letters (TISCopyCurrentASCIICapableKeyboardLayoutInputSource returns the layout
        /// itself, so a chord has no other layout to fall back to); else US is the ASCII-capable layout.
        var asciiCapable = true
        /// Keys that are dead keys with no modifier (their readings give the spacing accent).
        var deadKeys: Set<UInt16> = []
        var testDescription: String { name }

        nonisolated struct Pair: Sendable {
            let base: String
            let shifted: String
        }

        /// Whether the layout types `character` on some key with no modifier.
        func typesUnshifted(_ character: String) -> Bool {
            keys.values.contains { $0.base == character }
        }

        /// Whether the layout types ASCII on `keyCode` (else the ASCII-capable layout answers chords).
        func typesASCII(_ keyCode: UInt16) -> Bool {
            keys[keyCode].map { $0.base.allSatisfy(\.isASCII) } ?? true
        }
    }

    /// US ABC, the ASCII-capable layout of every fixture.
    nonisolated static let usRows: [(UInt16, String, String)] = [
        (0, "a", "A"), (1, "s", "S"), (2, "d", "D"), (3, "f", "F"), (4, "h", "H"), (5, "g", "G"), (6, "z", "Z"),
        (7, "x", "X"), (8, "c", "C"), (9, "v", "V"), (11, "b", "B"), (12, "q", "Q"), (13, "w", "W"), (14, "e", "E"),
        (15, "r", "R"), (16, "y", "Y"), (17, "t", "T"), (18, "1", "!"), (19, "2", "@"), (20, "3", "#"), (21, "4", "$"),
        (22, "6", "^"), (23, "5", "%"), (24, "=", "+"), (25, "9", "("), (26, "7", "&"), (27, "-", "_"), (28, "8", "*"),
        (29, "0", ")"), (30, "]", "}"), (31, "o", "O"), (32, "u", "U"), (33, "[", "{"), (34, "i", "I"), (35, "p", "P"),
        (37, "l", "L"), (38, "j", "J"), (39, "'", "\""), (40, "k", "K"), (41, ";", ":"), (42, "\\", "|"), (43, ",", "<"),
        (44, "/", "?"), (45, "n", "N"), (46, "m", "M"), (47, ".", ">"), (50, "`", "~"),
    ]

    nonisolated static func pairs(_ rows: [(UInt16, String, String)]) -> [UInt16: Layout.Pair] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.0, Layout.Pair(base: $0.1, shifted: $0.2)) })
    }

    /// Letters typed in place of the US letter on the same key (`q` -> `й`), uppercase shifted.
    nonisolated static func letters(_ map: [(String, String)], over base: [UInt16: Layout.Pair] = pairs(usRows)) -> [UInt16: Layout.Pair] {
        var keys = base
        let codes = Dictionary(uniqueKeysWithValues: usRows.map { ($0.1, $0.0) })
        for (us, typed) in map {
            guard let code = codes[us] else { continue }
            keys[code] = Layout.Pair(base: typed, shifted: typed.uppercased())
        }
        return keys
    }

    nonisolated static let us = Layout(name: "US", keys: pairs(usRows), command: [:])

    /// The US keys a non-Latin fixture keeps as they are: the digits, `-` and `=` (its own
    /// punctuation is left out rather than guessed; T2 reads the real layouts).
    nonisolated static let digitsAndLetterKeys: [UInt16: Layout.Pair] = pairs(usRows.filter { row in
        row.1.count == 1 && (row.1.first?.isLetter == true || row.1.first?.isNumber == true || row.1 == "-" || row.1 == "=")
    })

    /// com.apple.keylayout.Russian (ЙЦУКЕН); Command types QWERTY.
    nonisolated static let russian = Layout(name: "Russian", keys: letters([
        ("q", "й"), ("w", "ц"), ("e", "у"), ("r", "к"), ("t", "е"), ("y", "н"), ("u", "г"), ("i", "ш"), ("o", "щ"), ("p", "з"),
        ("[", "х"), ("]", "ъ"), ("a", "ф"), ("s", "ы"), ("d", "в"), ("f", "а"), ("g", "п"), ("h", "р"), ("j", "о"), ("k", "л"),
        ("l", "д"), (";", "ж"), ("'", "э"), ("z", "я"), ("x", "ч"), ("c", "с"), ("v", "м"), ("b", "и"), ("n", "т"), ("m", "ь"),
        (",", "б"), (".", "ю"),
    ], over: digitsAndLetterKeys), command: pairs(usRows), asciiCapable: false)

    /// com.apple.keylayout.Greek; Command types QWERTY.
    nonisolated static let greek = Layout(name: "Greek", keys: letters([
        ("w", "ς"), ("e", "ε"), ("r", "ρ"), ("t", "τ"), ("y", "υ"), ("u", "θ"), ("i", "ι"), ("o", "ο"), ("p", "π"), ("a", "α"),
        ("s", "σ"), ("d", "δ"), ("f", "φ"), ("g", "γ"), ("h", "η"), ("j", "ξ"), ("k", "κ"), ("l", "λ"), ("z", "ζ"), ("x", "χ"),
        ("c", "ψ"), ("v", "ω"), ("b", "β"), ("n", "ν"), ("m", "μ"),
    ], over: digitsAndLetterKeys), command: pairs(usRows), asciiCapable: false)

    /// com.apple.keylayout.Hebrew; Command types QWERTY.
    nonisolated static let hebrew = Layout(name: "Hebrew", keys: letters([
        ("e", "ק"), ("r", "ר"), ("t", "א"), ("y", "ט"), ("u", "ו"), ("i", "ן"), ("o", "ם"), ("p", "פ"), ("a", "ש"), ("s", "ד"),
        ("d", "ג"), ("f", "כ"), ("g", "ע"), ("h", "י"), ("j", "ח"), ("k", "ל"), ("l", "ך"), ("z", "ז"), ("x", "ס"), ("c", "ב"),
        ("v", "ה"), ("b", "נ"), ("n", "מ"), ("m", "צ"),
    ], over: digitsAndLetterKeys), command: pairs(usRows), asciiCapable: false)

    /// com.apple.keylayout.German (QWERTZ): Z and Y swap places; letters are matched where they are
    /// typed. `[` `]` `{` `}` `\\` `@` are Option characters, so Cmd-[ has no key (T2 reports such gaps).
    nonisolated static let german: Layout = {
        var keys = letters([("y", "z"), ("z", "y")])
        let typed: [(UInt16, String, String)] = [
            (19, "2", "\""), (20, "3", "§"), (22, "6", "&"), (26, "7", "/"), (28, "8", "("), (25, "9", ")"), (29, "0", "="),
            (27, "ß", "?"), (33, "ü", "Ü"), (30, "+", "*"), (41, "ö", "Ö"), (39, "ä", "Ä"), (42, "#", "'"), (43, ",", ";"),
            (47, ".", ":"), (44, "-", "_"),
        ]
        for (code, base, shifted) in typed { keys[code] = Layout.Pair(base: base, shifted: shifted) }
        // The dead-key key right of ß and the keys left of 1 and Z are left out.
        for code: UInt16 in [24, 50] { keys[code] = nil }
        return Layout(name: "German", keys: keys, command: [:])
    }()

    /// com.apple.keylayout.French (AZERTY): A/Q and Z/W swap, M is right of L, the digit row types
    /// `& é " ' ( § è ! ç à` and the digits only shifted, also with Command.
    nonisolated static let french: Layout = {
        var keys = letters([("q", "a"), ("a", "q"), ("w", "z"), ("z", "w"), (";", "m")])
        let typed: [(UInt16, String, String)] = [
            (18, "&", "1"), (19, "é", "2"), (20, "\"", "3"), (21, "'", "4"), (23, "(", "5"), (22, "§", "6"), (26, "è", "7"),
            (28, "!", "8"), (25, "ç", "9"), (29, "à", "0"), (27, ")", "°"), (24, "-", "_"), (30, "$", "*"), (39, "ù", "%"),
            (46, ",", "?"), (43, ";", "."), (47, ":", "/"), (44, "=", "+"),
        ]
        for (code, base, shifted) in typed { keys[code] = Layout.Pair(base: base, shifted: shifted) }
        // The dead ^ next to P: AppKit's readings give the spacing accent; the layout's data says dead.
        // The ` key next to Return and the key left of 1 are left out.
        keys[33] = Layout.Pair(base: "^", shifted: "¨")
        for code: UInt16 in [42, 50] { keys[code] = nil }
        var layout = Layout(name: "French", keys: keys, command: [:])
        layout.deadKeys = [33]
        return layout
    }()

    nonisolated static let dvorakLetters: [(String, String)] = [
        ("q", "'"), ("w", ","), ("e", "."), ("r", "p"), ("t", "y"), ("y", "f"), ("u", "g"), ("i", "c"), ("o", "r"), ("p", "l"),
        ("s", "o"), ("d", "e"), ("f", "u"), ("g", "i"), ("h", "d"), ("j", "h"), ("k", "t"), ("l", "n"), (";", "s"), ("z", ";"),
        ("x", "q"), ("c", "j"), ("v", "k"), ("b", "x"), ("n", "b"), (",", "w"), (".", "v"), ("/", "z"),
        ("[", "/"), ("]", "="), ("-", "["), ("=", "]"), ("'", "-"),
    ]

    /// com.apple.keylayout.Dvorak: shortcuts follow the Dvorak letters.
    nonisolated static let dvorak = Layout(name: "Dvorak", keys: letters(dvorakLetters), command: [:])

    /// com.apple.keylayout.DVORAK-QWERTYCMD: Dvorak typing, QWERTY with Command (the layout's purpose).
    nonisolated static let dvorakQwertyCommand = Layout(name: "Dvorak - QWERTY Command", keys: letters(dvorakLetters), command: pairs(usRows))

    /// com.apple.keylayout.French-PC (AZERTY, PC): the 6 key types `-` (Ctrl-- is Go Back, not tab 6).
    nonisolated static let frenchPC: Layout = {
        var keys = french.keys
        keys[22] = Layout.Pair(base: "-", shifted: "6")
        keys[27] = Layout.Pair(base: ")", shifted: "°")
        keys[24] = Layout.Pair(base: "=", shifted: "+")
        keys[44] = Layout.Pair(base: "!", shifted: "§")
        keys[28] = Layout.Pair(base: "_", shifted: "8")
        return Layout(name: "French - PC", keys: keys, command: [:])
    }()

    nonisolated static let layouts: [Layout] = [us, russian, greek, hebrew, german, french, frenchPC, dvorak, dvorakQwertyCommand]

    // MARK: Building keys

    /// The key `keyCode` of `layout` with `modifiers`, as AppKit reports it (`characters` with the
    /// Command key map when Command is held, `charactersIgnoringModifiers` from the base map with
    /// Shift only, `characters(byApplyingModifiers: [])`), read the way ``KeyInput/init(_:layout:composing:)``
    /// reads an `NSEvent`. Option is not modelled (its characters are the layout's Option map).
    static func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, on layout: Layout) -> KeyInput? {
        guard let base = layout.keys[keyCode] else { return nil }
        let shift = modifiers.contains(.shift)
        let typed = modifiers.contains(.command) ? layout.command[keyCode] ?? base : base
        let fallback = !layout.asciiCapable && !layout.typesASCII(keyCode) ? us.keys[keyCode]?.base : nil
        let positional = KeyInput.positionalPunctuation(keyCode: keyCode, keyTypes: base.base, isDead: layout.deadKeys.contains(keyCode), iso: false,
                                                        layoutTypes: layout.typesUnshifted)
        return KeyInput(keyCode: keyCode, modifiers: modifiers, text: shift ? typed.shifted : typed.base,
                        ignoringModifiers: shift ? base.shifted : base.base, unshifted: base.base,
                        commandUnshifted: modifiers.contains(.command) ? typed.base : nil, asciiFallback: fallback,
                        positional: positional)
    }

    /// The physical key the person presses for `shortcut` on `layout`: the digit row for a digit
    /// (Ghostty's `digit_N`); with Command, the key the Command map labels with the character;
    /// else the key that types it, or on a non-ASCII key the one whose Latin legend it is.
    static func keyCode(for shortcut: Shortcut, on layout: Layout) -> UInt16? {
        let character = shortcut.key
        if character.count == 1, character.first?.isASCII == true, character.first?.isNumber == true {
            return usRows.first { $0.1 == character }?.0
        }
        let candidates = layout.keys.keys.sorted()
        if shortcut.modifiers.contains(.command),
           let code = candidates.first(where: { (layout.command[$0] ?? layout.keys[$0])?.base == character }) {
            return code
        }
        if let code = candidates.first(where: { layout.keys[$0]?.base == character }) { return code }
        // Punctuation the layout moved to an Option layer: its US ANSI key, when the app's rule reads it
        // there (``KeyInput/positionalPunctuation``); else the chord has no key on this layout.
        if let code = KeyInput.usPunctuation.first(where: { $0.value == character })?.key, let base = layout.keys[code],
           KeyInput.positionalPunctuation(keyCode: code, keyTypes: base.base, isDead: layout.deadKeys.contains(code), iso: false,
                                          layoutTypes: layout.typesUnshifted) == character {
            return code
        }
        guard !layout.asciiCapable else { return nil }
        return candidates.first { !layout.typesASCII($0) && us.keys[$0]?.base == character }
    }

    /// A digit chord whose digit-row key types another character that is itself bound here
    /// (Cmd-6 on French - PC, whose 6 key types -, where Cmd-- zooms out): the typed character
    /// wins, as in every Mac app. Such a key must then take the US step of that character; nil
    /// when the digit is not shadowed.
    static func shadowingStep(_ shortcut: Shortcut, code: UInt16, on layout: Layout, in registry: ActionRegistry) -> String? {
        guard shortcut.key.first?.isNumber == true, let typed = layout.keys[code]?.base, typed != shortcut.key,
              registry.resolveShortcut(for: KeyInput(keyCode: code, modifiers: shortcut.modifiers, text: typed, ignoringModifiers: typed,
                                                     unshifted: typed)) != nil,
              let usCode = keyCode(for: Shortcut(typed, modifiers: shortcut.modifiers), on: us),
              let usKey = key(usCode, shortcut.modifiers, on: us) else { return nil }
        return step(usKey, after: [], in: registry)
    }

    static func registry(_ context: ActionContext = []) -> ActionRegistry {
        // The app binds a handler to every catalog action; a key runs only a bound one.
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        registry.context = context
        return registry
    }

    /// Every default single-key shortcut with Command or Control and no Option, on one printable key.
    static func defaultChords(in registry: ActionRegistry) -> [Shortcut] {
        var seen = Set<Shortcut>()
        return ActionCatalog.all.compactMap { registry.effectiveShortcut(for: $0.id) }.filter { shortcut in
            shortcut.key.count == 1 && shortcut.key.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
                && !shortcut.modifiers.isDisjoint(with: [.command, .control]) && !shortcut.modifiers.contains(.option)
                && seen.insert(shortcut).inserted
        }
    }

    // MARK: Every default chord on every layout

    /// Each default Command or Control chord runs the same action on `layout` as on US, pressed
    /// where the person finds it: Cmd-T on Russian is the key with the Latin T (it types е), Ctrl-B
    /// there too, Cmd-1 on AZERTY is the & key, Cmd-C on Dvorak - QWERTY ⌘ is QWERTY's C. A chord
    /// whose character the layout does not type (Cmd-[ on German) is not checked here; T2 counts it.
    @Test(arguments: layouts, [ActionContext(), .terminalFocused, .browserFocused])
    func everyDefaultChordRunsItsActionOnEveryLayout(layout: Layout, context: ActionContext) throws {
        let registry = Self.registry(context)
        var checked = 0
        var wrong: [String] = []
        for shortcut in Self.defaultChords(in: registry) {
            guard let usCode = Self.keyCode(for: shortcut, on: Self.us),
                  let usKey = Self.key(usCode, shortcut.modifiers, on: Self.us),
                  let expected = registry.resolveShortcut(for: usKey)?.id,
                  let code = Self.keyCode(for: shortcut, on: layout),
                  let key = Self.key(code, shortcut.modifiers, on: layout) else { continue }
            checked += 1
            if let shadowing = Self.shadowingStep(shortcut, code: code, on: layout, in: registry) {
                let got = Self.step(key, after: [], in: registry)
                if got != shadowing { wrong.append("\(shortcut.displayString) (key \(code), shadowed): \(got), not \(shadowing)") }
                continue
            }
            let resolved = registry.resolveShortcut(for: key)?.id
            if resolved != expected {
                wrong.append("\(shortcut.displayString) (key \(code), types \(key.text ?? "nil")): \(resolved?.rawValue ?? "nothing"), not \(expected)")
            }
        }
        #expect(checked > 10, "only \(checked) default chords checked on \(layout.name)")
        #expect(wrong.isEmpty, "\(layout.name) in \(context): \(wrong.count) of \(checked) default chords run another action:\n\(wrong.joined(separator: "\n"))")
    }

    // MARK: The chord path (the key router's sequence step), not only the single-key lookup

    /// What the router's chord step does with a first key or a next key, as a comparable string.
    static func step(_ key: KeyInput, after keys: [Shortcut], in registry: ActionRegistry) -> String {
        let bindings = RegistryKeyBindings(registry)
        let context = KeyContext(bits: registry.context)
        let readings = ActionRegistry.shortcuts(for: key, armed: !keys.isEmpty)
        switch bindings.table.step(after: keys, readings: readings, in: context, isRunnable: { bindings.canPerform($0, in: context.bits) }) {
        case .run(let winner): return "run \(winner.command)"
        case .extend(let shortcut): return "extend \(shortcut.displayString)"
        case .none: return "none"
        }
    }

    /// A first key takes the same chord step on every layout as on US: the key router runs
    /// `KeyBindingTable.step` before the single-key lookup, so a reading that arms the leader must
    /// not win over an earlier reading that runs (Cmd-C on Dvorak - QWERTY ⌘ also reads j: Cmd-J).
    @Test(arguments: layouts, [ActionContext(), .terminalFocused, .browserFocused])
    func everyDefaultChordTakesTheSameChordStepOnEveryLayout(layout: Layout, context: ActionContext) throws {
        let registry = Self.registry(context)
        var checked = 0
        var wrong: [String] = []
        for shortcut in Self.defaultChords(in: registry) {
            guard let usCode = Self.keyCode(for: shortcut, on: Self.us), let usKey = Self.key(usCode, shortcut.modifiers, on: Self.us),
                  let code = Self.keyCode(for: shortcut, on: layout), let key = Self.key(code, shortcut.modifiers, on: layout) else { continue }
            checked += 1
            let expected = Self.shadowingStep(shortcut, code: code, on: layout, in: registry) ?? Self.step(usKey, after: [], in: registry)
            let got = Self.step(key, after: [], in: registry)
            if got != expected { wrong.append("\(shortcut.displayString) (key \(code)): \(got), not \(expected)") }
        }
        #expect(checked > 10, "only \(checked) default chords checked on \(layout.name)")
        #expect(wrong.isEmpty, "\(layout.name) in \(context): \(wrong.count) of \(checked) chord steps differ:\n\(wrong.joined(separator: "\n"))")
    }

    /// The key after Cmd-J runs the same leader chord on every layout: an armed chord's next key is
    /// not typing, so it reads the ASCII-capable layout's key too (Cmd-J then the S key on Russian,
    /// which types ы, is New Agent Chat).
    @Test(arguments: layouts)
    func leaderChordsRunOnEveryLayout(layout: Layout) throws {
        let registry = Self.registry()
        var checked = 0
        var wrong: [String] = []
        for (id, second) in LeaderLayer.defaultChords {
            guard let usCode = Self.keyCode(for: second, on: Self.us), let usKey = Self.key(usCode, second.modifiers, on: Self.us),
                  let code = Self.keyCode(for: second, on: layout), let key = Self.key(code, second.modifiers, on: layout) else { continue }
            checked += 1
            let expected = Self.step(usKey, after: [LeaderLayer.prefix], in: registry)
            let got = Self.step(key, after: [LeaderLayer.prefix], in: registry)
            #expect(expected.hasPrefix("run"), "\(id) does not run after Cmd-J on US: \(expected)")
            if got != expected { wrong.append("\(id) (key \(code), types \(key.text ?? "nil")): \(got), not \(expected)") }
        }
        #expect(checked >= 3, "only \(checked) leader chords checked on \(layout.name)")
        #expect(wrong.isEmpty, "\(layout.name): \(wrong.joined(separator: "\n"))")
    }

    // MARK: Ghostty's getEvent order, one key at a time

    /// "set: getEvent codepoint case folding": Shift-T types T, the binding names t with Shift.
    @Test func shiftedTextMatchesTheLowercaseBinding() throws {
        let registry = Self.registry()
        let reopen = try #require(Self.defaultChords(in: registry).first { $0.modifiers == [.command, .shift] && $0.key == "t" })
        let key = KeyInput(keyCode: UInt16(kVK_ANSI_T), modifiers: [.command, .shift], text: "T", ignoringModifiers: "T", unshifted: "t")
        #expect(ActionRegistry.shortcuts(for: key).first == reopen)
    }

    /// Text of more than one character is no reading (Ghostty skips it); the unshifted key still matches.
    @Test func multiCharacterTextFallsBackToTheUnshiftedKey() {
        let key = KeyInput(keyCode: UInt16(kVK_ANSI_T), modifiers: [.command], text: "tt", ignoringModifiers: "tt", unshifted: "t")
        #expect(ActionRegistry.shortcuts(for: key).contains(Shortcut("t", modifiers: [.command])))
        #expect(!ActionRegistry.shortcuts(for: key).contains(Shortcut("tt", modifiers: [.command])))
    }

    /// An Option chord's Option character (ƒ for Cmd-Opt-F) is no reading: the key reads as its
    /// letter first, as the shortcut recorder records it.
    @Test func optionCharacterIsNoReading() {
        let key = KeyInput(keyCode: UInt16(kVK_ANSI_F), modifiers: [.command, .option], text: "ƒ", ignoringModifiers: "f", unshifted: "f")
        #expect(Array(ActionRegistry.shortcuts(for: key)) == [Shortcut("f", modifiers: [.command, .option])])
    }

    /// Dvorak - QWERTY ⌘ Cmd-Shift-]: the key types } with Command and = without; the Command map's
    /// unshifted ] is read before the layout's own =.
    @Test func commandMapsUnshiftedKeyIsReadBeforeTheLayoutsOwn() throws {
        let key = try #require(Self.key(UInt16(kVK_ANSI_RightBracket), [.command, .shift], on: Self.dvorakQwertyCommand))
        let readings = Array(ActionRegistry.shortcuts(for: key))
        #expect(readings.prefix(2) == [Shortcut("}", modifiers: [.command, .shift]), Shortcut("]", modifiers: [.command, .shift])])
    }

    /// Russian Cmd-T: the text (Command's QWERTY map) is read before the layout's own letter.
    @Test func commandTextIsReadBeforeTheLayoutsLetter() throws {
        let key = try #require(Self.key(UInt16(kVK_ANSI_T), [.command], on: Self.russian))
        #expect(ActionRegistry.shortcuts(for: key).first == Shortcut("t", modifiers: [.command]))
    }

    /// Russian Ctrl-B (a tmux-style prefix): no map types b, so the ASCII-capable layout's key is the last reading.
    @Test func controlChordOnANonLatinKeyFallsBackToTheASCIILayout() throws {
        let key = try #require(Self.key(UInt16(kVK_ANSI_B), [.control], on: Self.russian))
        let readings = Array(ActionRegistry.shortcuts(for: key))
        #expect(readings.last == Shortcut("b", modifiers: [.control]))
        #expect(readings.first == Shortcut("и", modifiers: [.control]))
    }

    /// AZERTY Cmd-&: the typed & first (Ghostty's unicode trigger), then the digit row's 1
    /// (`digit_1`): & has no binding, so Cmd-& is Cmd-1.
    @Test func digitRowFollowsTheTypedCharacter() throws {
        let key = try #require(Self.key(UInt16(kVK_ANSI_1), [.command], on: Self.french))
        #expect(Array(ActionRegistry.shortcuts(for: key)).prefix(2) == [Shortcut("&", modifiers: [.command]), Shortcut("1", modifiers: [.command])])
    }

    /// French - PC Ctrl--: the 6 key types -, which is Go Back; the digit 6 never wins over it.
    @Test func aTypedCharacterWinsOverTheDigitRow() throws {
        let registry = Self.registry()
        let key = try #require(Self.key(22, [.control], on: Self.frenchPC))
        let usKey = try #require(Self.key(UInt16(kVK_ANSI_Minus), [.control], on: Self.us))
        #expect(registry.resolveShortcut(for: key)?.id == registry.resolveShortcut(for: usKey)?.id)
        #expect(ActionRegistry.shortcuts(for: key).first == Shortcut("-", modifiers: [.control]))
    }

    /// A layout with a Command key map (Dvorak - QWERTY ⌘, Russian): with Command held, a key never
    /// reads the character it types without Command. Every key, not only the default chords:
    /// QWERTY Cmd-X is the Dvorak Q key and must not read q (Quit).
    @Test(arguments: [dvorakQwertyCommand, russian, greek, hebrew])
    func commandKeysReadOnlyTheCommandMap(layout: Layout) throws {
        for code in layout.keys.keys.sorted() {
            for modifiers: NSEvent.ModifierFlags in [[.command], [.command, .shift]] {
                guard let key = Self.key(code, modifiers, on: layout), let base = layout.keys[code],
                      let command = layout.command[code], command.base != base.base else { continue }
                let plain = Set([base.base, base.shifted].map { Shortcut($0, modifiers: modifiers) })
                let read = ActionRegistry.shortcuts(for: key).filter(plain.contains)
                #expect(read.isEmpty, "\(layout.name) key \(code) with Command reads \(read.map(\.key)), its plain characters")
            }
        }
    }

    /// German QWERTZ: letters are never physical. The key at US Y types z and is Cmd-Z, not Cmd-Y.
    @Test func lettersAreNeverMatchedByPosition() throws {
        let key = try #require(Self.key(UInt16(kVK_ANSI_Y), [.command], on: Self.german))
        #expect(Array(ActionRegistry.shortcuts(for: key)) == [Shortcut("z", modifiers: [.command])])
    }

    // MARK: Punctuation the layout moves (audit item 1)

    /// The registry's step for a US key and for `key`, in `context`.
    static func sameStepAsUS(_ key: KeyInput, usKeyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, in context: ActionContext) throws
        -> (got: String, expected: String) {
        let registry = registry(context)
        let usKey = try #require(Self.key(usKeyCode, modifiers, on: us))
        return (step(key, after: [], in: registry), step(usKey, after: [], in: registry))
    }

    /// German Cmd-ü and Cmd-+ (the keys US has [ and ] on: German types [ ] only with Option) are
    /// Cmd-[ and Cmd-]; with Shift, Cmd-Shift-[ and Cmd-Shift-] (previous and next tab).
    @Test(arguments: [ActionContext(), .terminalFocused, .browserFocused])
    func bracketsMovedToOptionAreReachedByPosition(context: ActionContext) throws {
        for (code, modifiers) in [(UInt16(33), NSEvent.ModifierFlags.command), (30, [.command]), (33, [.command, .shift]), (30, [.command, .shift])] {
            let key = try #require(Self.key(code, modifiers, on: Self.german))
            let (got, expected) = try Self.sameStepAsUS(key, usKeyCode: code, modifiers, in: context)
            #expect(expected != "none", "US key \(code) with \(modifiers.rawValue) runs nothing in \(context)")
            #expect(got == expected, "German key \(code) with \(modifiers.rawValue): \(got), not \(expected)")
        }
    }

    /// Ctrl-` (New Terminal Tab) on an ISO German keyboard: the key left of 1 is kVK_ISO_Section (10)
    /// and types the dead ^ (no text): Ctrl and that key is Ctrl-`. The extra key left of Z
    /// (kVK_ANSI_Grave, 50, types <) names nothing.
    @Test func graveIsTheKeyLeftOfOneOnISO() throws {
        let positional = KeyInput.positionalPunctuation(keyCode: 10, keyTypes: "^", isDead: true, iso: true, layoutTypes: Self.german.typesUnshifted)
        #expect(positional == "`")
        let key = KeyInput(keyCode: 10, modifiers: [.control], text: nil, ignoringModifiers: "^", unshifted: "^", positional: positional)
        let (got, expected) = try Self.sameStepAsUS(key, usKeyCode: 50, [.control], in: [])
        #expect(expected != "none")
        #expect(got == expected, "German ISO Ctrl and the key left of 1: \(got), not \(expected)")
        #expect(KeyInput.positionalPunctuation(keyCode: 50, keyTypes: "<", isDead: false, iso: true, layoutTypes: Self.german.typesUnshifted) == nil)
    }

    /// French Cmd and the dead ^ key (US [): the dead key types nothing, so it names [ by position,
    /// though AppKit's readings give the spacing ^ (ASCII).
    @Test(arguments: [ActionContext(), .terminalFocused, .browserFocused])
    func aDeadKeyKeepsItsPosition(context: ActionContext) throws {
        let key = try #require(Self.key(33, [.command], on: Self.french))
        #expect(key.positional == "[")
        let (got, expected) = try Self.sameStepAsUS(key, usKeyCode: 33, [.command], in: context)
        #expect(got == expected, "French Cmd and the dead ^ key: \(got), not \(expected)")
    }

    /// Never steal a key the layout types: German, Spanish and Italian type + on the key US has ]
    /// (Cmd-+ is zoom there), French types $ on it: neither reads ] by position.
    @Test(arguments: [ActionContext(), .terminalFocused, .browserFocused])
    func aKeyThatTypesASCIIPunctuationKeepsIt(context: ActionContext) throws {
        let key = try #require(Self.key(30, [.command], on: Self.german))
        #expect(key.positional == nil)
        #expect(!ActionRegistry.shortcuts(for: key).contains(Shortcut("]", modifiers: [.command])))
        let registry = Self.registry(context)
        #expect(Self.step(key, after: [], in: registry) == Self.step(KeyInput(keyCode: 30, modifiers: [.command], text: "+",
                                                                               ignoringModifiers: "+", unshifted: "+"), after: [], in: registry))
        #expect(KeyInput.positionalPunctuation(keyCode: 30, keyTypes: "$", isDead: false, iso: false, layoutTypes: Self.french.typesUnshifted) == nil)
    }

    /// Never steal a key the layout types: Dvorak types [ itself (on US's - key), so Cmd and the key
    /// US has [ on (Dvorak's /) reads / and never [.
    @Test func aLayoutThatTypesTheCharacterKeepsItsKey() throws {
        let key = try #require(Self.key(33, [.command], on: Self.dvorak))
        #expect(!ActionRegistry.shortcuts(for: key).contains(Shortcut("[", modifiers: [.command])))
        #expect(key.positional == nil)
    }

    /// The position is the last reading: German Cmd-ü reads ü first, so a binding on Cmd-ü wins.
    @Test func thePositionIsTheLastReading() throws {
        let key = try #require(Self.key(33, [.command], on: Self.german))
        #expect(Array(ActionRegistry.shortcuts(for: key)) == [Shortcut("ü", modifiers: [.command]), Shortcut("[", modifiers: [.command])])
    }

    // MARK: Plain and Option keys

    /// The matcher adds nothing to a plain, Shift or Option key on any layout: no physical digit and
    /// no ASCII fallback, so typing `&` on AZERTY or `е` on Russian never reads as 1 or t.
    @Test(arguments: layouts)
    func plainAndOptionKeysOnlyReadWhatTheyType(layout: Layout) {
        for code in layout.keys.keys.sorted() {
            for modifiers in [NSEvent.ModifierFlags(), [.shift], [.option], [.shift, .option]] {
                guard let base = Self.key(code, modifiers.subtracting(.option), on: layout) else { continue }
                // Option's own characters are the layout's Option map; any one of them reads the same way.
                let key = KeyInput(keyCode: code, modifiers: modifiers, text: base.text, ignoringModifiers: base.ignoringModifiers,
                                   unshifted: base.unshifted, asciiFallback: base.asciiFallback)
                let typed = Set([key.text, key.ignoringModifiers, key.unshifted].compactMap { $0 }.map { Shortcut($0, modifiers: modifiers) })
                let extra = ActionRegistry.shortcuts(for: key).filter { !typed.contains($0) }
                #expect(extra.isEmpty, "\(layout.name) key \(code) with \(modifiers.rawValue): \(extra.map(\.key)) is not what it types")
            }
        }
    }
}
