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
    var size: CGFloat = 16

    var body: some View {
        let tone = Self.toneColor(Self.hashTone(identity))
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

    /// The Mac's `hashTone`: FNV-1a of the UTF-16 units, modulo the five tones.
    static func hashTone(_ id: String) -> Int {
        var hash: UInt32 = 0x811c9dc5
        for unit in id.utf16 { hash = (hash ^ UInt32(unit)) &* 0x01000193 }
        return Int(hash % 5)
    }

    /// The tones' colors, the Mac's terminal-color fallbacks (subagents.css `[data-agent-tone]`).
    static func toneColor(_ tone: Int) -> Color {
        [Color.green, .purple, .yellow, .cyan, .pink][tone % 5]
    }
}
