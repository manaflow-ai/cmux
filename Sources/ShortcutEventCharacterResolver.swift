import AppKit

/// Resolves and caches the character planes used to match one AppKit key event.
///
/// Plain Command events trust `characters` because AppKit has already applied
/// command-aware layouts such as Dvorak–QWERTY ⌘. When Option or Control is
/// also held, those modifiers must not alter the shortcut key, so the exact
/// current-layout Command/Shift plane is resolved first. A non-ASCII
/// `charactersIgnoringModifiers` value preserves key-code-less Unicode
/// bindings if exact retranslation is unavailable. The ASCII-capable layout is
/// a separate fallback and is consulted only after those exact values miss.
final class ShortcutEventCharacterResolver {
    typealias ExactCharacterProvider = (NSEvent, NSEvent.ModifierFlags) -> String?
    typealias LayoutCharacterProvider = (UInt16, NSEvent.ModifierFlags) -> String?

    let event: NSEvent

    private let exactCharacterProvider: ExactCharacterProvider
    private let layoutCharacterProvider: LayoutCharacterProvider
    private let normalizedModifierFlags: NSEvent.ModifierFlags
    private var didResolvePrimaryCharacters = false
    private var cachedPrimaryCharacters: String?
    private var didResolveASCIIFallbackCharacters = false
    private var cachedASCIIFallbackCharacters: String?

    init(
        event: NSEvent,
        exactCharacterProvider: @escaping ExactCharacterProvider,
        layoutCharacterProvider: @escaping LayoutCharacterProvider
    ) {
        self.event = event
        self.exactCharacterProvider = exactCharacterProvider
        self.layoutCharacterProvider = layoutCharacterProvider
        normalizedModifierFlags = ShortcutStroke.normalizedModifierFlags(
            from: event.modifierFlags
        )
    }

    static func live(
        for event: NSEvent,
        layoutCharacterProvider: @escaping LayoutCharacterProvider =
            KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> ShortcutEventCharacterResolver {
        ShortcutEventCharacterResolver(
            event: event,
            exactCharacterProvider: { event, modifiers in
                event.characters(byApplyingModifiers: modifiers)
            },
            layoutCharacterProvider: layoutCharacterProvider
        )
    }

    var primaryCharacters: String? {
        if !didResolvePrimaryCharacters {
            cachedPrimaryCharacters = resolvePrimaryCharacters()
            didResolvePrimaryCharacters = true
        }
        return cachedPrimaryCharacters
    }

    var asciiFallbackCharacters: String? {
        if !didResolveASCIIFallbackCharacters {
            cachedASCIIFallbackCharacters = layoutCharacterProvider(
                event.keyCode,
                normalizedModifierFlags
            )
            didResolveASCIIFallbackCharacters = true
        }
        return cachedASCIIFallbackCharacters
    }

    private func resolvePrimaryCharacters() -> String? {
        guard normalizedModifierFlags.contains(.command) else {
            return event.charactersIgnoringModifiers
        }
        guard normalizedModifierFlags.contains(.option)
            || normalizedModifierFlags.contains(.control) else {
            return event.characters
        }

        let commandPlaneModifiers = normalizedModifierFlags.intersection([
            .command,
            .shift,
        ])
        if let exactCharacters = exactCharacterProvider(
            event,
            commandPlaneModifiers
        ), !exactCharacters.isEmpty {
            return exactCharacters
        }

        if let charactersIgnoringModifiers = event.charactersIgnoringModifiers,
           charactersIgnoringModifiers.unicodeScalars.contains(where: { !$0.isASCII }) {
            return charactersIgnoringModifiers
        }
        return nil
    }
}
