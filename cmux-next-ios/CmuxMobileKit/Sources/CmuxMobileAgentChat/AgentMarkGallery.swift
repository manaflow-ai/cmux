#if DEBUG && os(iOS)
import CmuxAgentBrands
import CmuxMobileDesign
import SwiftUI

/// How a terminal agent's avatar differs from a GUI agent chat's (Leo, 2026-11-24: "terminal agent
/// chats. can they be demarcated a bit differently/should they? than gui agent chats. both of them
/// rn are just claude icon. ... a small subscript symbol? but wouldn't that look kinda
/// dingleberry-esque?"). A is the one the app draws (`AgentRunSurface`); B, C and D are the
/// variants it was picked from, drawn only here.
public enum AgentMarkGalleryVariant: String, CaseIterable, Identifiable, Sendable {
    /// The shipped one: the same mark, a rounded square ("a terminal window") in place of the circle.
    case tile = "a"
    /// The subscript Leo asked about: a small `>_` badge on the circle's corner.
    case badge = "b"
    /// A `>` prompt folded into the mark, on the same circle.
    case prompt = "c"
    /// The circle unchanged; a quiet "Terminal" after the agent's name.
    case label = "d"

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .tile: "A · Tile (shipped)"
        case .badge: "B · Corner badge"
        case .prompt: "C · Prompt glyph"
        case .label: "D · Row label"
        }
    }

    var verdict: String {
        switch self {
        case .tile: "Nothing added to the mark: the container's shape carries it, and stays clean at 16 pt."
        case .badge: "Reads at 40 pt, but a speck on every terminal row: the clutter Leo worried about."
        case .prompt: "Says \"terminal\" plainly, but shrinks the agent's mark to make room."
        case .label: "Clearest in words, but costs header width on every row, and the avatar still lies."
        }
    }
}

/// One avatar drawn in one variant.
struct AgentMarkVariantAvatar: View {
    let variant: AgentMarkGalleryVariant
    let harness: String
    let surface: AgentRunSurface
    let side: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch variant {
        case .tile:
            AgentAvatar(harness: harness, side: side, surface: surface)
        case .label:
            AgentAvatar(harness: harness, side: side)
        case .badge:
            AgentAvatar(harness: harness, side: side)
                .overlay(alignment: .bottomTrailing) {
                    if surface == .terminal {
                        Text(">_")
                            .font(.system(size: max(6, side * 0.2), weight: .heavy, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, max(1.5, side * 0.05))
                            .background(Color.black, in: RoundedRectangle(cornerRadius: max(2, side * 0.08), style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: max(2, side * 0.08), style: .continuous)
                                .strokeBorder(Color.cmuxMobileBackground, lineWidth: 1.5))
                            .offset(x: side * 0.08, y: side * 0.08)
                    }
                }
        case .prompt:
            if surface == .terminal {
                HStack(spacing: side * 0.02) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: side * 0.2, weight: .bold))
                        .foregroundStyle(.secondary)
                    AgentBrandMark(agent: AgentSenderIcon.family(harness), size: (side * 0.38).rounded(), style: .brand)
                }
                .offset(x: -side * 0.03)
                .frame(width: side, height: side)
                .background(tint, in: Circle())
            } else {
                AgentAvatar(harness: harness, side: side)
            }
        }
    }

    private var tint: Color {
        guard let spec = AgentAvatarMark.spec(harness: harness, side: side) else { return .cmuxMobileSurfaceRaised }
        let fill = AgentAvatarMark.fill(spec, dark: colorScheme == .dark)
        return Color(red: Double((fill.rgb >> 16) & 0xFF) / 255, green: Double((fill.rgb >> 8) & 0xFF) / 255,
                     blue: Double(fill.rgb & 0xFF) / 255).opacity(fill.opacity)
    }
}

/// The gallery: `-cmux-mobile-recovery-gallery agentmark` puts every variant side by side;
/// `agentmark-a` (… `-d`) draws one variant as Feed rows, with the Mac tab strip below.
public struct AgentMarkGallery: View {
    let variant: AgentMarkGalleryVariant?

    public init(variant: String? = nil) {
        self.variant = variant.flatMap(AgentMarkGalleryVariant.init(rawValue:))
    }

    private struct Sample: Identifiable {
        let harness: String
        let surface: AgentRunSurface
        var id: String { "\(harness)-\(surface.rawValue)" }
    }

    /// Four avatars: Claude and Codex, each as a chat and in a terminal.
    private static let samples = [
        Sample(harness: "claude", surface: .chat), Sample(harness: "claude", surface: .terminal),
        Sample(harness: "codex", surface: .chat), Sample(harness: "codex", surface: .terminal),
    ]

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let variant {
                    rows(variant)
                } else {
                    Text("Chat · Terminal, for Claude and Codex")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(AgentMarkGalleryVariant.allCases) { overview($0) }
                }
            }
            .padding(16)
        }
        .background(Color.cmuxMobileBackground)
    }

    private func overview(_ variant: AgentMarkGalleryVariant) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(variant.title).font(.subheadline.weight(.semibold))
            ForEach([CGFloat(40), 24], id: \.self) { side in
                HStack(spacing: side >= 40 ? 18 : 14) {
                    ForEach(Self.samples) { sample in
                        HStack(spacing: 4) {
                            AgentMarkVariantAvatar(variant: variant, harness: sample.harness, surface: sample.surface, side: side)
                            if variant == .label, sample.surface == .terminal, side >= 40 {
                                Text("Terminal").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Text(variant.verdict).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agentMarkGallery.\(variant.rawValue)")
    }

    /// One variant as Feed rows draw it, then the Mac's tab strip with the shipped treatment.
    private func rows(_ variant: AgentMarkGalleryVariant) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(variant.title).font(.headline)
            Text(variant.verdict).font(.footnote).foregroundStyle(.secondary)
            feedRow(variant, harness: "claude", surface: .chat, name: "Claude", place: "api-server › Fix login redirect",
                    text: "Done. The redirect now keeps the original path; tests pass.")
            feedRow(variant, harness: "claude", surface: .terminal, name: "Claude", place: "cmux › zsh",
                    text: "Wants to run `cargo test -p cmux-tui`. Allow?")
            feedRow(variant, harness: "codex", surface: .chat, name: "Codex", place: "web › Pricing page",
                    text: "Moved the plan cards into one grid and fixed the overflow on small widths.")
            feedRow(variant, harness: "codex", surface: .terminal, name: "Codex", place: "infra › bash",
                    text: "Finished: 14 runner labels audited, 3 renamed.")
            Divider()
            Text("Mac tab strip (shipped: a terminal agent's mark on a tile)").font(.footnote.weight(.semibold))
            MacTabStripSample()
        }
        .accessibilityIdentifier("agentMarkGallery.rows.\(variant.rawValue)")
    }

    private func feedRow(_ variant: AgentMarkGalleryVariant, harness: String, surface: AgentRunSurface,
                         name: String, place: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AgentMarkVariantAvatar(variant: variant, harness: harness, surface: surface, side: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(name).font(.subheadline.weight(.semibold))
                    if variant == .label, surface == .terminal {
                        Text("Terminal").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    Text("· \(place)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("· 2m").font(.subheadline).foregroundStyle(.secondary)
                }
                Text(text).font(.subheadline).lineLimit(2)
            }
        }
    }
}

/// The Mac's tab strip as it draws agent tabs: a chat's mark bare, a terminal agent's on a tinted
/// rounded square (`TabAgentMarkCache`'s tile), so the two apps read alike.
private struct MacTabStripSample: View {
    var body: some View {
        HStack(spacing: 6) {
            tab("Fix login redirect", harness: "claude", terminal: false)
            tab("zsh", harness: "claude", terminal: true)
            tab("bash", harness: "codex", terminal: true)
        }
    }

    private func tab(_ title: String, harness: String, terminal: Bool) -> some View {
        HStack(spacing: 6) {
            if terminal {
                AgentBrandMark(agent: harness, size: 11)
                    .frame(width: 16, height: 16)
                    .background(Color.primary.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: AgentRunSurface.terminal.cornerRadius(side: 16), style: .continuous))
            } else {
                AgentBrandMark(agent: harness, size: 14).frame(width: 16, height: 16)
            }
            Text(title).font(.caption).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.cmuxMobileSurfaceRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
#endif
