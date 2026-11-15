import AppKit

/// The font picker's own keys, read before the palette's key map while its page shows.
public enum PaletteFontTunerKey: Equatable, Sendable {
    /// Tab and Shift-Tab: the next or previous target.
    case target(Int)
    /// Cmd-= and Cmd--: the size, one step.
    case size(Int)
    /// Option-Cmd-= and Option-Cmd--: the line height, one step.
    case lineHeight(Int)

    /// The key `event` is on the font picker, or nil (the palette's own keys then apply).
    static func key(for event: NSEvent) -> PaletteFontTunerKey? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 48 {
            if flags.isEmpty { return .target(1) }
            if flags == .shift { return .target(-1) }
            return nil
        }
        guard flags.contains(.command), !flags.contains(.control) else { return nil }
        let characters = event.charactersIgnoringModifiers ?? ""
        let delta: Int? = switch characters {
        // Cmd-+ is Cmd-Shift-= on most layouts; both grow.
        case "=", "+": 1
        case "-", "_": -1
        default: nil
        }
        guard let delta else { return nil }
        return flags.contains(.option) ? .lineHeight(delta) : .size(delta)
    }
}

extension PaletteModel {
    /// Runs a font picker key. False when no font picker shows.
    @discardableResult
    public func handleFontTuner(_ key: PaletteFontTunerKey) -> Bool {
        guard let tuner = fontTuner else { return false }
        switch key {
        case .target(let delta): selectFontTarget(tuner.targetIndex + delta)
        case .size(let delta): tuner.stepSize(delta)
        case .lineHeight(let delta): tuner.stepLineHeight(delta)
        }
        return true
    }

    /// Shows the font picker's target at `index` (wrapping) in the current page's place, keeping the
    /// typed query: the list changes, the dock under it stays where it is.
    public func selectFontTarget(_ index: Int) {
        guard let tuner = fontTuner, tuner.selectTarget(index) else { return }
        replaceCurrentPage(with: PaletteFontPage.page(tuner, query: query))
    }
}
