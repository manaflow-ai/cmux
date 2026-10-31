#if os(iOS)
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// A team row (SPEC 3.3): 36 pt avatar, team name, and up to five Mac presence
/// dots (green online, gray offline) followed by "+N". 60 pt tall; the selected
/// row gets a `fillSelected` rounded background.
public struct SidebarTeamRow: View {
    let name: String
    let colorHex: String?
    let emoji: String?
    let transparent: Bool
    let dots: [Bool]
    let overflow: Int
    let onlineCount: Int
    let isSelected: Bool

    public init(name: String, colorHex: String?, emoji: String?, transparent: Bool = false, dots: [Bool], overflow: Int, onlineCount: Int, isSelected: Bool) {
        self.name = name
        self.colorHex = colorHex
        self.emoji = emoji
        self.transparent = transparent
        self.dots = dots
        self.overflow = overflow
        self.onlineCount = onlineCount
        self.isSelected = isSelected
    }

    /// The gap from the avatar column to the name.
    public static let avatarGap: CGFloat = 12
    /// The name's x in the drawer: the side margin, the avatar column, the gap.
    /// The drawer's section label and Invite to team start here too.
    public static var textLeading: CGFloat {
        theme.metrics.sideMargin + theme.metrics.teamAvatar + avatarGap
    }

    public var body: some View {
        HStack(spacing: Self.avatarGap) {
            TeamAvatar(name: name, colorHex: colorHex, emoji: emoji, size: theme.metrics.teamAvatar, transparent: transparent)
            VStack(alignment: .leading, spacing: 5) {
                Text(name)
                    .font(theme.type.rowTitle.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(theme.colors.label)
                    .lineLimit(1)
                MacPresenceDots(dots: dots, overflow: overflow)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.metrics.sideMargin - theme.metrics.selectedRowInset)
        .frame(height: theme.metrics.teamRowHeight)
        .background {
            RoundedRectangle(cornerRadius: theme.metrics.selectedRowRadius, style: .continuous)
                .fill(theme.colors.fillSelected)
                .opacity(isSelected ? 1 : 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(dots.isEmpty ? "No Macs yet" : "\(onlineCount) of \(dots.count + overflow) Macs online"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Up to five 7 pt dots, 4 pt apart, then "+N"; "No Macs yet" when empty.
public struct MacPresenceDots: View {
    let dots: [Bool]
    let overflow: Int

    public init(dots: [Bool], overflow: Int) {
        self.dots = dots
        self.overflow = overflow
    }

    public var body: some View {
        HStack(spacing: theme.metrics.macDotSpacing) {
            if dots.isEmpty {
                Text("No Macs yet").font(theme.type.meta).foregroundStyle(theme.colors.label2)
            }
            ForEach(Array(dots.enumerated()), id: \.offset) { _, online in
                Circle()
                    .fill(online ? theme.colors.success : theme.colors.offline)
                    .frame(width: theme.metrics.macDot, height: theme.metrics.macDot)
                    .animation(theme.motion.snap.animation, value: online)
            }
            if overflow > 0 {
                Text(verbatim: "+\(overflow)")
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.label2)
                    .padding(.leading, 2)
            }
        }
        .frame(height: 16)
    }
}
#endif

#if os(iOS)
/// The tag that tells same-name Macs apart ("3F2A"), drawn next to the name
/// wherever a row shows it (Workspaces, Settings → Devices). Text elsewhere
/// spells it "Aziz's MacBook Pro 3F2A" (`MacNameDisambiguation.displayName`).
public struct MacNameTag: View {
    let tag: String
    /// 11 pt at Large, growing with Dynamic Type up to twice that: beside a
    /// name it must never squeeze the name (at accessibility sizes rows put it
    /// on its own line under the name).
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 11

    public init(_ tag: String) {
        self.tag = tag
    }

    public var body: some View {
        Text(verbatim: tag)
            .font(.system(size: min(size, 22), weight: .semibold, design: .monospaced))
            .foregroundStyle(theme.colors.label2)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(theme.colors.fillSelected, in: .rect(cornerRadius: 6, style: .continuous))
            .fixedSize()
    }
}
#endif
