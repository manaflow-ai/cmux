#if DEBUG
import CmuxNextDesign
import SwiftUI

/// DEBUG ONLY (Environment Secrets Playground): two static terminal frames of the proposed CLI,
/// `cmux secrets set` (the value from a hidden prompt, never an argument) and `cmux secrets list`
/// (no value column at all). The same frames in every direction: the CLI has no direction.
struct EnvTerminalFrames: View {
    private let set: [(String, Color?)] = [
        ("$ cmux secrets set STRIPE_SECRET_KEY --host api.stripe.com --header \"Authorization: Bearer {value}\" --scope team", nil),
        ("Value for STRIPE_SECRET_KEY (hidden, not echoed): ", Color(nsColor: .systemTeal)),
        ("Again to confirm: ", Color(nsColor: .systemTeal)),
        ("Touch ID: confirm a new host for a team secret… approved by Mia Chen", Color(nsColor: .systemOrange)),
        ("✓ Saved STRIPE_SECRET_KEY  version 4  •••• Q7rT  → api.stripe.com", Color(nsColor: .systemGreen)),
        ("  The value cannot be read back. Agents get the placeholder $STRIPE_SECRET_KEY.", Color(white: 0.62)),  // colour-allow: a static terminal frame draws fixed terminal colours in both looks
        ("", nil),
        ("$ pbpaste | cmux secrets set MAPS_API_KEY --host maps.googleapis.com --query key", nil),
        ("✓ Saved MAPS_API_KEY  version 1  •••• Lk2w  → maps.googleapis.com", Color(nsColor: .systemGreen)),
        ("", nil),
        ("$ cmux secrets set NPM_TOKEN sk_live_123", nil),
        ("✗ A secret value is never an argument: it shows in ps and in shell history.", Color(nsColor: .systemRed)),
        ("  Type it at the hidden prompt, or pipe it: pbpaste | cmux secrets set NPM_TOKEN --setup-only", Color(white: 0.62)),  // colour-allow: a static terminal frame draws fixed terminal colours in both looks
    ]

    private let list: [(String, Color?)] = [
        ("$ cmux secrets list", nil),
        ("NAME                 TYPE        LAST 4  HOSTS                     SCOPE     SET BY           SET      LAST USE", Color(white: 0.62)),  // colour-allow: a static terminal frame draws fixed terminal colours in both looks
        ("STRIPE_SECRET_KEY    api         Q7rT    api.stripe.com            team      Mia Chen         Nov 18   4 min ago", nil),
        ("                                         + hooks.stripe.com        (waiting for an admin's Touch ID)", Color(nsColor: .systemOrange)),
        ("DATADOG_API_KEY      api         c41e    api.datadoghq.com +1      team      Jordan Lee       Nov 12   1 h ago", nil),
        ("NPM_TOKEN            setup-only  aB12    —                         team      Mia Chen         Oct 30   today", nil),
        ("LEGACY_LICENSE       in-env  ⚠   9f3c    —                         team      Priya Natarajan  Oct 2    2 d ago", nil),
        ("STRIPE_SECRET_KEY    api         m3Dx    api.stripe.com            personal  you              Nov 19   never", nil),
        ("", nil),
        ("$ cmux secrets get STRIPE_SECRET_KEY", nil),
        ("✗ There is no get: a saved secret is never shown again. Use cmux secrets set to replace it.", Color(nsColor: .systemRed)),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Terminal: the same operations, and no way to read a value back").font(.system(size: TypeScale.title, weight: .semibold))
                frame(title: "cmux secrets set", lines: set)
                frame(title: "cmux secrets list", lines: list)
            }
            .padding(22)
        }
    }

    private func frame(title: String, lines: [(String, Color?)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.75)).frame(width: 10, height: 10) }  // visible-only: fixed sample list of at most 4 items
                Spacer()
                Text(title).font(.system(size: TypeScale.caption)).foregroundStyle(Color.white.opacity(0.55))
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(white: 0.17))  // colour-allow: a static terminal frame draws fixed terminal colours in both looks
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in  // visible-only: fixed sample list of 13 lines
                    Text(line.0.isEmpty ? " " : line.0)
                        .font(.system(size: TypeScale.detail, design: .monospaced))
                        .foregroundStyle(line.1 ?? Color(white: 0.92))  // colour-allow: a static terminal frame draws fixed terminal colours in both looks
                        .lineLimit(1).fixedSize()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.09))  // colour-allow: a static terminal frame draws fixed terminal colours in both looks
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(EnvInk.line))
        .environment(\.colorScheme, .dark)
    }
}
#endif
