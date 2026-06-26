public import AppKit

/// Owns the keyboard-shortcut event-decode state and transforms for the app's
/// configured-shortcut routing.
///
/// ## Responsibility
///
/// This is the orchestration owner for turning a raw keyboard `NSEvent` into the
/// layout-aware character and numbered-digit values the app's shortcut matchers
/// compare against bound shortcuts. It conforms to ``ShortcutEventDecoding``,
/// the read-only seam the app target depends on, and holds the one piece of
/// mutable-by-injection state that decode needs: the layout-character provider.
///
/// It is the first cohesive sub-cluster of a larger shortcut-routing domain. The
/// per-keystroke dispatch (`handleCustomShortcut` and the split/browser/quit/
/// group shortcut bodies, plus the focus-context cache that wraps live browser
/// and markdown panels) stays in the app target for now because it reaches
/// window, tab, and AppKit-responder state that cannot cross a module boundary;
/// those move in follow-up slices that invert their app-target collaborators
/// behind seams. This type drains the decode half, which is pure.
///
/// ## Isolation
///
/// `@MainActor` because its only callers are the AppKit local key-event monitor
/// handler and the menu-shortcut suppressor, both of which run on the main
/// thread (the same isolation ruling as `ShortcutChordCoordinator`: state lives
/// where its callers live, so no cross-actor bridge is introduced on the
/// keystroke hot path).
///
/// ## Injection
///
/// The layout-character provider is constructor-injected so tests substitute a
/// deterministic layout. The app composition root injects the live
/// Carbon-backed provider; tests pass a closure returning fixed characters.
@MainActor
public final class ShortcutCoordinator: ShortcutEventDecoding {
    /// The layout-character provider decode reads. Settable so tests substitute a
    /// deterministic layout after construction (the app's
    /// `AppDelegateShortcutRoutingTests` swap this between a fixed closure and the
    /// live Carbon-backed default mid-test); production sets it once at the
    /// composition root.
    public var layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String?

    /// Creates a coordinator decoding events through `layoutCharacterProvider`.
    ///
    /// - Parameter layoutCharacterProvider: Resolves a physical key code plus
    ///   modifier flags to the character the current keyboard layout produces for
    ///   shortcut matching. The app injects the live input-source-backed
    ///   provider; tests inject a deterministic one.
    public init(
        layoutCharacterProvider: @escaping (UInt16, NSEvent.ModifierFlags) -> String?
    ) {
        self.layoutCharacterProvider = layoutCharacterProvider
    }

    public func layoutCharacter(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> String? {
        layoutCharacterProvider(keyCode, modifierFlags)
    }

    public func normalizedShortcutEventCharacter(
        _ eventCharacter: String,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> String {
        // Forwards to the package's single normalization table. This decoder's
        // historical behavior normalized "+"/"_" only under Shift, so it passes
        // normalizePlusMinusRegardlessOfShift: false (the configured-shortcut
        // matcher passes true for the European dedicated-key case).
        PhysicalShortcutKey(keyCode: eventKeyCode).normalizedEventCharacter(
            eventCharacter,
            applyShiftSymbolNormalization: applyShiftSymbolNormalization,
            normalizePlusMinusRegardlessOfShift: false
        )
    }

    public func numberedShortcutDigit(
        eventKeyCode: UInt16,
        eventCharactersIgnoringModifiers: String?,
        eventModifierFlags: NSEvent.ModifierFlags,
        requireModifierFlags: NSEvent.ModifierFlags
    ) -> Int? {
        let flags = eventModifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags == requireModifierFlags else { return nil }
        let numberKeyDigit = Self.digitForNumberKeyCode(eventKeyCode)

        if let digit = numberedShortcutDigit(
            eventCharacter: eventCharactersIgnoringModifiers,
            applyShiftSymbolNormalization: flags.contains(.shift),
            eventKeyCode: eventKeyCode
        ) {
            return digit
        }

        let hasUsableASCIIEventChars = !(eventCharactersIgnoringModifiers?.isEmpty ?? true)
            && (eventCharactersIgnoringModifiers?.allSatisfy(\.isASCII) ?? true)
        if !hasUsableASCIIEventChars || numberKeyDigit != nil {
            let layoutCharacter = layoutCharacterProvider(eventKeyCode, eventModifierFlags)
            if let digit = numberedShortcutDigit(
                eventCharacter: layoutCharacter,
                applyShiftSymbolNormalization: false,
                eventKeyCode: eventKeyCode
            ) {
                return digit
            }
        }

        return numberKeyDigit
    }

    /// The digit 1–9 a physical number-row key code maps to, or `nil`. The 0 key
    /// (kVK_ANSI_0, keyCode 29) is intentionally excluded: numbered shortcuts run
    /// 1–9 only. Faithful relocation of `AppDelegate.digitForNumberKeyCode(_:)`.
    private static func digitForNumberKeyCode(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1 // kVK_ANSI_1
        case 19: return 2 // kVK_ANSI_2
        case 20: return 3 // kVK_ANSI_3
        case 21: return 4 // kVK_ANSI_4
        case 23: return 5 // kVK_ANSI_5
        case 22: return 6 // kVK_ANSI_6
        case 26: return 7 // kVK_ANSI_7
        case 28: return 8 // kVK_ANSI_8
        case 25: return 9 // kVK_ANSI_9
        default:
            return nil
        }
    }

    /// Resolves a single printed/layout character to a digit 1–9 after
    /// normalization, or `nil`. Faithful relocation of the app's
    /// `numberedShortcutDigit(eventCharacter:applyShiftSymbolNormalization:eventKeyCode:)`.
    private func numberedShortcutDigit(
        eventCharacter: String?,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> Int? {
        guard let eventCharacter, !eventCharacter.isEmpty else { return nil }
        let normalized = normalizedShortcutEventCharacter(
            eventCharacter,
            applyShiftSymbolNormalization: applyShiftSymbolNormalization,
            eventKeyCode: eventKeyCode
        )
        guard let digit = Int(normalized), (1...9).contains(digit) else { return nil }
        return digit
    }
}
