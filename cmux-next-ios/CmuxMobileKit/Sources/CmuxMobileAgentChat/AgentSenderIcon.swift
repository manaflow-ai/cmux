import CmuxAgentBrands
import SwiftUI

/// A sender's icon, as the Mac's `webviews/src/agent-session/acpmux/subagents/SenderIcon.tsx` draws
/// it by default: the model family's mark big and a small diamond at its bottom right in the
/// session's own tone, so two Claude sessions read as Claude and as two (Leo, 2026-11-05: "we ought
/// to just have it be the model family's icon ... and then you have the, like, colored either robot
/// symbol or the sort of, you know, the diamond symbol"). A sender with no family mark draws its
/// diamond alone, big, in its tone. The tone is the Mac's `agentTones.ts` `hashTone` of the same key.
struct AgentSenderIcon: View {
    let harness: String?
    /// The key the tone comes from: the sender's session id, else its name.
    let identity: String
    /// The tone the chat assigned the sender (`AgentTones`), else `identity`'s hash.
    var assignedTone: Int?
    var size: CGFloat = 16

    var body: some View {
        let tone = Self.toneColor(assignedTone ?? Self.hashTone(identity))
        let badge = (size * 0.58).rounded()
        Group {
            if AgentBrandCatalog.spec(forAgent: Self.family(harness)) != nil {
                AgentBrandMark(agent: Self.family(harness), size: size, style: .brand)
                    // The ring cut under the badge, so it reads on the card's fill.
                    .mask {
                        Rectangle()
                            .overlay(alignment: .bottomTrailing) {
                                Circle()
                                    .frame(width: badge + 2, height: badge + 2)
                                    .offset(x: badge * 0.25 + 1, y: badge * 0.25 + 1)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "sparkle")
                            .resizable()
                            .scaledToFit()
                            .frame(width: badge, height: badge)
                            .foregroundStyle(tone)
                            .offset(x: badge * 0.25, y: badge * 0.25)
                    }
            } else {
                Image(systemName: "sparkle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(tone)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The harness's own id when it has a mark, else its family's (`claude-sr2` → `claude`).
    static func family(_ harness: String?) -> String? {
        guard let harness, !harness.isEmpty else { return nil }
        if AgentBrandCatalog.spec(forAgent: harness) != nil { return harness }
        return harness.split(whereSeparator: { "-_/".contains($0) }).first.map(String.init)
    }

    /// The Mac's `hashTone`: FNV-1a of the UTF-16 units, modulo the five tones (`AgentTones`).
    static func hashTone(_ id: String) -> Int { AgentTones.hashTone(id) }

    /// The tones' colors: the Mac's own terminal-color fallbacks (subagents.css `[data-agent-tone]`),
    /// so a session reads in the same hue on both.
    static let toneRGB: [(Double, Double, Double)] = [
        (0x3f, 0xb9, 0x50), (0xa3, 0x71, 0xf7), (0xd2, 0x99, 0x22), (0x39, 0xc5, 0xcf), (0xdb, 0x61, 0xa2),
    ]

    static func toneColor(_ tone: Int) -> Color {
        let (r, g, b) = toneRGB[tone % toneRGB.count]
        return Color(red: r / 255, green: g / 255, blue: b / 255)
    }
}
