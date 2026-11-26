#if DEBUG && os(iOS)
import CmuxAgentBrands
import CmuxMobileDesign
import SwiftUI

/// Gallery: how a terminal agent (Claude Code in a terminal tab) is told apart from a GUI agent chat
/// (the native chat pane) when both wear the same mark. Leo 2026-11-24: "terminal agent chats. can
/// they be demarcated a bit differently/should they? than gui agent chats. both of them rn are just
/// claude icon. but one is terminal one is gui. should we do anything? how? a small subscript symbol?
/// but wouldn't that look kinda dingleberry-esque?"
///
/// Launch with `-cmux-mobile-recovery-gallery agentmark` (every variant side by side at the Feed's
/// 40 pt, the chats list's 32 pt and the 16 pt of a capsule or a Mac tab), or `agentmark-a` ... `agentmark-d`
/// (one variant on Feed-like rows). Screens only; it asserts no taste.
///
/// - A, `badge`: a `>_` disc at the bottom-right, cut out of the circle by a ring of the page's color.
/// - B, `tile`: a dark rounded-square "terminal tile" with the mark in its own colors.
/// - C, `label`: the avatar unchanged; the row's line says "Terminal" after a `>_` symbol.
/// - D, `shape`: the same soft tint, but a continuous rounded square instead of a circle (the shipped one,
///   `AgentAvatarHost.terminal`): the outline, not an extra part, says "terminal".
public struct AgentAvatarHostGallery: View {
    public enum Variant: String, CaseIterable, Identifiable, Sendable {
        case badge = "a", tile = "b", label = "c", shape = "d"
        public var id: String { rawValue }
        var title: String {
            switch self {
            case .badge: "A · cut-out >_ badge"
            case .tile: "B · dark terminal tile"
            case .label: "C · label only"
            case .shape: "D · rounded square (shipped)"
            }
        }
    }

    let variant: Variant?

    public init(variant: String?) {
        self.variant = variant.flatMap(Variant.init(rawValue:))
    }

    public var body: some View {
        ScrollView {
            if let variant {
                rows(variant)
            } else {
                overview
            }
        }
        .background(Color.cmuxMobileBackground)
    }

    // MARK: Overview

    private static let samples: [(harness: String, host: AgentAvatarHost)] = [
        ("claude", .chat), ("claude", .terminal), ("codex", .chat), ("codex", .terminal),
        ("gemini", .terminal), ("terminal", .terminal),
    ]

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Agent marks: GUI chat vs terminal")
                .font(.headline)
            ForEach(Variant.allCases) { variant in
                VStack(alignment: .leading, spacing: 8) {
                    Text(variant.title).font(.subheadline.weight(.semibold))
                    HStack(alignment: .top, spacing: 10) {
                        // visible-only: six fixed gallery samples, never a live list.
                        ForEach(Array(Self.samples.enumerated()), id: \.offset) { _, sample in
                            VStack(spacing: 6) {
                                GalleryAvatar(harness: sample.harness, host: sample.host, variant: variant, side: 40)
                                GalleryAvatar(harness: sample.harness, host: sample.host, variant: variant, side: 32)
                                GalleryAvatar(harness: sample.harness, host: sample.host, variant: variant, side: 16)
                                Text(sample.host == .terminal ? "term" : "chat")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if variant == .label, sample.host == .terminal {
                                    TerminalHostLabel().font(.caption2)
                                }
                            }
                            .frame(width: 48)
                        }
                    }
                }
                Divider()
            }
        }
        .padding(16)
    }

    // MARK: Feed-like rows

    private struct Row: Identifiable {
        let id: Int
        let harness: String
        let host: AgentAvatarHost
        let name: String
        let place: String
        let body: String
        let age: String
    }

    private static let feed: [Row] = [
        Row(id: 0, harness: "claude", host: .chat, name: "Claude", place: "cmux › Fix login redirect",
            body: "The redirect now keeps the return URL. Tests pass.", age: "2m"),
        Row(id: 1, harness: "claude", host: .terminal, name: "Claude Code", place: "cmux-next-ios › tmux 2",
            body: "Waiting for approval: run `xcodebuild test`?", age: "4m"),
        Row(id: 2, harness: "codex", host: .terminal, name: "Codex", place: "fleet › runner labels",
            body: "Done. 3 files changed, 41 insertions.", age: "12m"),
        Row(id: 3, harness: "codex", host: .chat, name: "Codex", place: "cmux.com › pricing",
            body: "I moved the plan cards into one row on iPad.", age: "1h"),
        Row(id: 4, harness: "claude", host: .terminal, name: "Claude Code", place: "web › zsh",
            body: "Pushed lane/agent-chat-terminal-mark.", age: "3h"),
    ]

    private func rows(_ variant: Variant) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(variant.title)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            ForEach(Self.feed) { row in
                HStack(alignment: .top, spacing: 12) {
                    GalleryAvatar(harness: row.harness, host: row.host, variant: variant, side: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.name).font(.body.weight(.semibold))
                            Spacer(minLength: 4)
                            Text(row.age).font(.footnote).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Text(row.place).lineLimit(1)
                            if variant == .label, row.host == .terminal {
                                TerminalHostLabel()
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        Text(row.body).font(.subheadline).lineLimit(2)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider().padding(.leading, 68)
            }
            Text("Chats list (32 pt) and Working now (16 pt)")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 16)
            HStack(spacing: 14) {
                ForEach(Self.feed) { row in
                    GalleryAvatar(harness: row.harness, host: row.host, variant: variant, side: 32)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            HStack(spacing: 8) {
                ForEach(Self.feed) { row in
                    HStack(spacing: 6) {
                        GalleryAvatar(harness: row.harness, host: row.host, variant: variant, side: 16)
                        Text(row.name).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.cmuxMobileFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// C's words: `>_ Terminal`, as secondary as the line it sits in.
private struct TerminalHostLabel: View {
    var body: some View {
        Label("Terminal", systemImage: "apple.terminal")
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
    }
}

/// One avatar drawn by `variant`'s rule. A GUI chat is always the shipped circle (`AgentAvatar`).
private struct GalleryAvatar: View {
    let harness: String
    let host: AgentAvatarHost
    let variant: AgentAvatarHostGallery.Variant
    let side: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if host == .chat {
            AgentAvatar(harness: harness, side: side)
        } else {
            switch variant {
            case .badge: badge
            case .tile: tile
            case .label: AgentAvatar(harness: harness, side: side)
            case .shape: AgentAvatar(harness: harness, side: side, host: .terminal)
            }
        }
    }

    /// A: the badge sits in the circle's corner; a ring of the page's color around it is cut out of
    /// the circle (a mask, not a stroke), so it reads as part of the avatar, the way iOS cuts a status
    /// badge out of an app icon.
    private var badge: some View {
        let disc = (side * 0.44).rounded()
        let ring = max(1, (side * 0.06).rounded())
        let offset = (side - disc) / 2
        return ZStack {
            AgentAvatar(harness: harness, side: side)
                .mask {
                    ZStack {
                        Rectangle()
                        Circle()
                            .frame(width: disc + ring * 2, height: disc + ring * 2)
                            .offset(x: offset + ring / 2, y: offset + ring / 2)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
            Circle()
                .fill(Color.primary)
                .frame(width: disc, height: disc)
                .overlay {
                    Text(">_")
                        .font(.system(size: disc * 0.46, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Color.cmuxMobileBackground)
                        .offset(y: -disc * 0.02)
                }
                .offset(x: offset + ring / 2, y: offset + ring / 2)
        }
        .frame(width: side, height: side)
    }

    /// B: a near-black tile whatever the scheme (a terminal's window), the mark in its dark colors.
    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: side * AgentAvatarMark.tileCornerShare, style: .continuous)
        return AgentBrandMark(agent: AgentSenderIcon.family(harness), size: (side * AgentAvatarMark.markShare).rounded(), style: .brand)
            .environment(\.colorScheme, .dark)
            .frame(width: side, height: side)
            .background(Color(white: colorScheme == .dark ? 0.17 : 0.12), in: shape)
            .overlay { shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0), lineWidth: 0.5) }
    }
}
#endif
