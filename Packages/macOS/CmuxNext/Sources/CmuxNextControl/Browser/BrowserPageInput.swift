/// One raw input of `browser.page.mouse|wheel|insert_text|key`, for an engine to deliver as native
/// input (``BrowserPageOperation/input(_:)``): trusted events that run the browser's default
/// actions. Points are viewport CSS pixels.
public enum BrowserPageInput: Sendable, Hashable {
    /// A modifier key held during the input.
    public enum Modifier: String, Sendable, Hashable, CaseIterable {
        case shift, control, alt, meta
    }

    /// A mouse button.
    public enum Button: String, Sendable, Hashable, CaseIterable {
        case left, middle, right, back, forward
    }

    /// What a mouse input does. `click` is a press, then a release.
    public enum MouseKind: String, Sendable, Hashable, CaseIterable {
        case down, up, move, click
    }

    /// What a key input does. `press` is a key down, then a key up.
    public enum KeyKind: String, Sendable, Hashable, CaseIterable {
        case down, up, press
    }

    /// A mouse input at (`x`, `y`); `clickCount` is 1 for a single click, 2 for a double one.
    case mouse(kind: MouseKind, x: Double, y: Double, button: Button, clickCount: Int, modifiers: Set<Modifier>)
    /// A wheel at (`x`, `y`) scrolling by (`dx`, `dy`) CSS pixels.
    case wheel(x: Double, y: Double, dx: Double, dy: Double, modifiers: Set<Modifier>)
    /// Text committed into the focused element, as typing or an input method commits it.
    case text(String)
    /// A key: `key` and `code` are its DOM `key` and `code` names, `keyCode` its legacy key code.
    case key(key: String, code: String, keyCode: Int, kind: KeyKind, modifiers: Set<Modifier>)
}
