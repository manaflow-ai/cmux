public import Foundation

/// A letter key the page did not handle while no editable field had focus
/// (Chromium's unhandled-key report). The host may run a single-key
/// shortcut on it (link hints); the page has already had its chance.
public nonisolated struct BrowserPageKey: Hashable, Sendable {
    /// The lowercase letter, `a` to `z`, or `/`.
    public var character: String
    public var shift: Bool

    public init(character: String, shift: Bool) {
        self.character = character.lowercased()
        self.shift = shift
    }

    /// From a Windows virtual key code (`VK_A` 0x41 to `VK_Z` 0x5A, or
    /// `VK_OEM_2` 0xBF, the `/` key of a US layout); nil for any other key.
    /// cmux binds nothing of its own to `/`; an extension's page key may.
    public init?(windowsKeyCode: Int, shift: Bool) {
        if windowsKeyCode == Self.slashKeyCode {
            self.init(character: "/", shift: shift)
            return
        }
        guard (0x41...0x5A).contains(windowsKeyCode), let scalar = Unicode.Scalar(windowsKeyCode + 0x20) else { return nil }
        self.init(character: String(Character(scalar)), shift: shift)
    }

    /// `VK_OEM_2`: the key that types `/` (and `?` with Shift) on a US layout.
    public static let slashKeyCode = 0xBF
}
