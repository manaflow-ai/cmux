#if DEBUG
import CmuxNextDesign
import AppKit

/// DEBUG ONLY (Environment Secrets Playground): two static terminal frames of the proposed CLI,
/// `cmux secrets set` (the value from a hidden prompt, never an argument) and `cmux secrets list`
/// (no value column at all). The same frames in every direction: the CLI has no direction.
struct EnvTerminalFrames {
    private let set: [(String, NSColor?)] = [
        ("$ cmux secrets set STRIPE_SECRET_KEY --host api.stripe.com --header \"Authorization: Bearer {value}\" --scope team", nil),
        ("Value for STRIPE_SECRET_KEY (hidden, not echoed): ", NSColor.systemTeal),
        ("Again to confirm: ", NSColor.systemTeal),
        ("Touch ID: confirm a new host for a team secret… approved by Mia Chen", NSColor.systemOrange),
        ("✓ Saved STRIPE_SECRET_KEY  version 4  •••• Q7rT  → api.stripe.com", NSColor.systemGreen),
        ("  The value cannot be read back. Agents get the placeholder $STRIPE_SECRET_KEY.", NSColor(white: 0.62, alpha: 1)),  // colour-allow: a static terminal frame draws fixed terminal colours in both looks
        ("", nil),
        ("$ pbpaste | cmux secrets set MAPS_API_KEY --host maps.googleapis.com --query key", nil),
        ("✓ Saved MAPS_API_KEY  version 1  •••• Lk2w  → maps.googleapis.com", NSColor.systemGreen),
        ("", nil),
        ("$ cmux secrets set NPM_TOKEN sk_live_123", nil),
        ("✗ A secret value is never an argument: it shows in ps and in shell history.", NSColor.systemRed),
        ("  Type it at the hidden prompt, or pipe it: pbpaste | cmux secrets set NPM_TOKEN --setup-only", NSColor(white: 0.62, alpha: 1)),  // colour-allow: a static terminal frame draws fixed terminal colours in both looks
    ]

    private let list: [(String, NSColor?)] = [
        ("$ cmux secrets list", nil),
        ("NAME                 TYPE        LAST 4  HOSTS                     SCOPE     SET BY           SET      LAST USE", NSColor(white: 0.62, alpha: 1)),  // colour-allow: a static terminal frame draws fixed terminal colours in both looks
        ("STRIPE_SECRET_KEY    api         Q7rT    api.stripe.com            team      Mia Chen         Nov 18   4 min ago", nil),
        ("                                         + hooks.stripe.com        (waiting for an admin's Touch ID)", NSColor.systemOrange),
        ("DATADOG_API_KEY      api         c41e    api.datadoghq.com +1      team      Jordan Lee       Nov 12   1 h ago", nil),
        ("NPM_TOKEN            setup-only  aB12    —                         team      Mia Chen         Oct 30   today", nil),
        ("LEGACY_LICENSE       in-env  ⚠   9f3c    —                         team      Priya Natarajan  Oct 2    2 d ago", nil),
        ("STRIPE_SECRET_KEY    api         m3Dx    api.stripe.com            personal  you              Nov 19   never", nil),
        ("", nil),
        ("$ cmux secrets get STRIPE_SECRET_KEY", nil),
        ("✗ There is no get: a saved secret is never shown again. Use cmux secrets set to replace it.", NSColor.systemRed),
    ]

    /// The two frames under their title, in a scroll view.
    func make() -> NSView { envScroll(content()) }

    /// The two frames under their title, with no vertical scroll view: for a page that scrolls as a whole. A
    /// terminal line never wraps and is never cut off; a frame narrower than its longest line scrolls sideways.
    func content() -> NSView {
        let title = envLabel("Terminal: the same operations, and no way to read a value back", size: TypeScale.title, weight: .semibold)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let column = envV([title, frame(title: "cmux secrets set", lines: set), frame(title: "cmux secrets list", lines: list)],
                          spacing: 18, fill: true)
        return EnvBox(column, padding: envPad(22))
    }

    private func frame(title: String, lines: [(String, NSColor?)]) -> NSView {
        let dots: [NSView] = [NSColor.systemRed, .systemYellow, .systemGreen].map {  // visible-only: the three window dots
            envSized(EnvBox(nil, fill: envAlpha($0, 0.75), corner: .capsule), width: 10, height: 10)
        }
        let titleInk = NSColor(white: 1, alpha: 0.55)  // colour-allow: a static terminal frame draws fixed terminal colours in both looks
        let (left, right) = (envSpacer(), envSpacer())
        let barRow = envH(dots + [left, envLabel(title, size: TypeScale.caption, color: titleInk), right], spacing: 6)
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        let bar = EnvBox(barRow,
                         padding: envPad(h: 10, v: 7), fill: NSColor(white: 0.17, alpha: 1))  // colour-allow: a static terminal frame draws fixed terminal colours in both looks
        // As in a terminal, a line never wraps and is never cut: a frame narrower than its longest line scrolls
        // sideways, so the list's columns stay lined up.
        let text: [NSView] = lines.map { line in  // visible-only: a fixed sample of at most 13 lines
            let label = envLabel(line.0.isEmpty ? " " : line.0, color: line.1 ?? NSColor(white: 0.92, alpha: 1), mono: true)  // colour-allow: a static terminal frame draws fixed terminal colours in both looks
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            return label
        }
        let lineStack = EnvBox(envV(text, spacing: 3), padding: envPad(12))
        let body = EnvBox(envHScroll(lineStack), fill: NSColor(white: 0.09, alpha: 1))  // colour-allow: a static terminal frame draws fixed terminal colours in both looks
        let frame = EnvBox(envV([bar, body], spacing: 0, fill: true), border: EnvInk.line, corner: .radius(8))
        frame.wantsLayer = true
        frame.layer?.cornerRadius = 8
        frame.layer?.masksToBounds = true
        return frame
    }
}
#endif
