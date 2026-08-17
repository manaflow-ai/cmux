import AppKit
import CmuxSidebar
import SwiftUI

struct SessionCard: View {
    let snapshot: SessionCardSnapshot
    let isActive: Bool
    let isHovered: Bool
    let fontScale: CGFloat
    let makesPullRequestsClickable: Bool
    let onRestart: () -> Void
    let onClose: () -> Void
    let onOpenPullRequest: (URL) -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            SessionCardSpine(colorHex: snapshot.colorHex)
                .padding(.vertical, 7)

            VStack(alignment: .leading, spacing: 7) {
                topRow
                hostRow
                if !snapshot.pullRequests.isEmpty {
                    pullRequestRows
                }
                if snapshot.branchName != nil {
                    branchRow
                }
                footerRow
            }
            .padding(.vertical, 9)
            .padding(.leading, 15)
            .padding(.trailing, 11)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeInOut(duration: 0.16), value: isActive)
        .animation(.easeInOut(duration: 0.16), value: isHovered)
    }

    private var topRow: some View {
        HStack(spacing: 8) {
            SessionCardBadge(
                badge: snapshot.badge,
                colorHex: snapshot.colorHex,
                fontScale: fontScale
            )

            Text(snapshot.name)
                .font(.custom("Inter", size: scaled(12.5)).weight(.semibold))
                .foregroundColor(hexColor("#EAEAEF"))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRestart) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: scaled(9), weight: .semibold))
                    .foregroundColor(hexColor("#8A8A95"))
                    .frame(width: scaled(20), height: scaled(20))
                    .background(
                        Circle()
                            .fill(Color.white.opacity(isHovered ? 0.08 : 0.001))
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .help(restartHelpText)
            .accessibilityLabel(Text(restartHelpText))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: scaled(9), weight: .semibold))
                    .foregroundColor(hexColor("#8A8A95"))
                    .frame(width: scaled(20), height: scaled(20))
                    .background(
                        Circle()
                            .fill(Color.white.opacity(isHovered ? 0.08 : 0.001))
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .help(String(localized: "sidebar.workspace.closeButton", defaultValue: "Close Workspace"))
            .accessibilityLabel(Text(String(localized: "sidebar.workspace.closeButton", defaultValue: "Close Workspace")))
        }
    }

    private var restartHelpText: String {
        String(localized: "sidebar.sessionCard.restart", defaultValue: "Restart Session")
    }

    private var hostRow: some View {
        HStack(spacing: 6) {
            Image(systemName: hostIconName)
                .font(.system(size: scaled(12), weight: .regular))
                .symbolRenderingMode(.monochrome)
                .frame(width: scaled(13), height: scaled(13))

            Text(snapshot.host.displayName)
                .font(.custom("Inter", size: scaled(11)))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .foregroundColor(hexColor("#8A8A95"))
    }

    private var pullRequestRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(snapshot.pullRequests) { pullRequest in
                let title = "\(pullRequest.label) #\(pullRequest.number)"
                let content = HStack(spacing: 6) {
                    Image(systemName: pullRequestIconName(pullRequest.status))
                        .font(.system(size: scaled(10), weight: .semibold))
                        .frame(width: scaled(13), height: scaled(13))

                    Text(title)
                        .underline(makesPullRequestsClickable)
                        .lineLimit(1)

                    Text(pullRequestStatusLabel(pullRequest.status))
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .font(.custom("Inter", size: scaled(10)).weight(.semibold))
                .foregroundColor(hexColor("#8A8A95"))
                .opacity(pullRequest.isStale ? 0.5 : 1)

                if makesPullRequestsClickable {
                    Button(action: { onOpenPullRequest(pullRequest.url) }) {
                        content
                    }
                    .buttonStyle(.plain)
                    .help(pullRequestOpenTooltip(pullRequest))
                    .accessibilityIdentifier("SidebarPullRequestRow")
                } else {
                    content
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("SidebarPullRequestRow")
                }
            }
        }
    }

    private var branchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: scaled(12), weight: .regular))
                .symbolRenderingMode(.monochrome)
                .frame(width: scaled(13), height: scaled(13))

            Text(snapshot.branchName ?? "")
                .font(.custom("JetBrains Mono", size: scaled(11)))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundColor(hexColor("#8A8A95"))
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            if let modeName = snapshot.mode.badgeDisplayName {
                Text(modeName)
                    .font(.custom("Inter", size: scaled(10)).weight(.semibold))
                    .foregroundColor(modeTextColor)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(modeBackgroundColor)
                    )
            }

            if let modelName = snapshot.modelName {
                Text(modelName)
                    .font(.custom("JetBrains Mono", size: scaled(11)).weight(.regular))
                    .foregroundColor(hexColor("#8A8A95"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            statusPill

            if !snapshot.diff.isEmpty {
                HStack(spacing: 5) {
                    Text("+\(snapshot.diff.added)")
                        .foregroundColor(hexColor("#3FB950"))
                    Text("-\(snapshot.diff.deleted)")
                        .foregroundColor(hexColor("#F85149"))
                }
                .font(.custom("JetBrains Mono", size: scaled(11)).weight(.medium))
                .lineLimit(1)
            }
        }
    }

    private var hostIconName: String {
        switch snapshot.host {
        case .laptop:
            return "laptopcomputer"
        case .devbox:
            return "server.rack"
        }
    }

    private func pullRequestIconName(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open:
            return "arrow.triangle.pull"
        case .merged:
            return "arrow.triangle.merge"
        case .closed:
            return "xmark.circle"
        }
    }

    private func pullRequestStatusLabel(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open:
            return String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged:
            return String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed:
            return String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
    }

    private func pullRequestOpenTooltip(_ pullRequest: SessionCardSnapshot.PullRequest) -> String {
        String(
            format: String(
                localized: "sidebar.pullRequest.openTooltip",
                defaultValue: "Open %@ #%lld"
            ),
            locale: .current,
            pullRequest.label,
            pullRequest.number
        )
    }

    private var sessionColor: Color {
        SessionCardColor.color(hex: snapshot.colorHex, fallbackHex: "#4493F8")
    }

    private var backgroundColor: Color {
        if isActive {
            return SessionCardColor.oklabMix(colorHex: snapshot.colorHex, amount: 0.22, over: "#17171C")
        }
        return SessionCardColor.oklabMix(colorHex: snapshot.colorHex, amount: 0.09, over: "#17171B")
    }

    private var borderColor: Color {
        if isActive {
            let amount: CGFloat = isHovered ? 0.56 : 0.42
            return SessionCardColor.oklabMix(colorHex: snapshot.colorHex, amount: amount, over: "#2A2A31")
        }
        return hexColor("#25252B")
    }

    private var modeBackgroundColor: Color {
        switch snapshot.mode {
        case .plan:
            return hexColor("#4493F8").opacity(0.15)
        case .edit:
            return hexColor("#D29922").opacity(0.17)
        case .defaultMode:
            return Color.white.opacity(0.055)
        }
    }

    private var modeTextColor: Color {
        switch snapshot.mode {
        case .plan:
            return hexColor("#78BBFF")
        case .edit:
            return hexColor("#E3B341")
        case .defaultMode:
            return hexColor("#9A9AA5")
        }
    }

    private var statusPill: some View {
        let color = snapshot.isPinned
            ? hexColor("#8A8A95")
            : SessionCardColor.color(hex: snapshot.status.colorHex, fallbackHex: "#8A8A95")
        let label = snapshot.isPinned
            ? String(localized: "sidebar.sessionCard.status.pinned", defaultValue: "Pinned")
            : snapshot.status.displayName
        let iconName = snapshot.isPinned ? "pin" : snapshot.status.iconName

        return HStack(spacing: 4) {
            if let iconName {
                Image(systemName: iconName)
                    .font(.system(size: scaled(9), weight: .semibold))
            }
            Text(label)
                .lineLimit(1)
        }
        .font(.custom("Inter", size: scaled(10)).weight(.semibold))
        .foregroundColor(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(color.opacity(0.14)))
        .overlay(Capsule(style: .continuous).strokeBorder(color.opacity(0.3), lineWidth: 0.5))
    }

    private func scaled(_ size: CGFloat) -> CGFloat {
        size * fontScale
    }

    private func hexColor(_ hex: String) -> Color {
        SessionCardColor.color(hex: hex, fallbackHex: "#FFFFFF")
    }
}

private struct SessionCardSpine: View {
    let colorHex: String

    var body: some View {
        Capsule(style: .continuous)
            .fill(SessionCardColor.color(hex: colorHex, fallbackHex: "#4493F8"))
            .frame(width: 3)
    }
}

private struct SessionCardBadge: View {
    let badge: SessionCardSnapshot.Badge
    let colorHex: String
    let fontScale: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fillColor)

            switch badge {
            case .indexedWorktree(let number):
                Text("\(number)")
                    .font(.custom("JetBrains Mono", size: scaled(12)).weight(.bold))
            case .unindexedHost(let host):
                Image(systemName: iconName(for: host))
                    .font(.system(size: scaled(12), weight: .semibold))
                    .symbolRenderingMode(.monochrome)
            }
        }
        .foregroundColor(hexColor("#0B0C0F"))
        .frame(width: 22, height: 22)
    }

    private var fillColor: Color {
        switch badge {
        case .indexedWorktree:
            return SessionCardColor.color(hex: colorHex, fallbackHex: "#4493F8")
        case .unindexedHost:
            return SessionCardColor.oklabMix(colorHex: colorHex, amount: 0.82, over: "#222229")
        }
    }

    private func iconName(for host: SessionCardSnapshot.Host) -> String {
        switch host {
        case .laptop:
            return "laptopcomputer"
        case .devbox:
            return "server.rack"
        }
    }

    private func scaled(_ size: CGFloat) -> CGFloat {
        size * fontScale
    }

    private func hexColor(_ hex: String) -> Color {
        SessionCardColor.color(hex: hex, fallbackHex: "#FFFFFF")
    }
}

private enum SessionCardColor {
    static func color(hex: String, fallbackHex: String) -> Color {
        Color(nsColor: nsColor(hex: hex, fallbackHex: fallbackHex))
    }

    static func oklabMix(colorHex: String, amount: CGFloat, over baseHex: String) -> Color {
        let color = OklabColor(nsColor: nsColor(hex: colorHex, fallbackHex: colorHex))
        let base = OklabColor(nsColor: nsColor(hex: baseHex, fallbackHex: baseHex))
        let clamped = max(0, min(amount, 1))
        let mixed = OklabColor(
            l: color.l * clamped + base.l * (1 - clamped),
            a: color.a * clamped + base.a * (1 - clamped),
            b: color.b * clamped + base.b * (1 - clamped)
        )
        return Color(nsColor: mixed.nsColor)
    }

    private static func nsColor(hex: String, fallbackHex: String) -> NSColor {
        NSColor(hex: hex) ?? NSColor(hex: fallbackHex) ?? .white
    }

    private struct OklabColor {
        let l: CGFloat
        let a: CGFloat
        let b: CGFloat

        init(l: CGFloat, a: CGFloat, b: CGFloat) {
            self.l = l
            self.a = a
            self.b = b
        }

        init(nsColor: NSColor) {
            let color = nsColor.usingColorSpace(.sRGB) ?? nsColor
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            _ = alpha

            let r = Self.srgbToLinear(red)
            let g = Self.srgbToLinear(green)
            let b = Self.srgbToLinear(blue)

            let long = Self.cubeRoot(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let medium = Self.cubeRoot(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let short = Self.cubeRoot(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)

            self.l = 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short
            self.a = 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short
            self.b = 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short
        }

        var nsColor: NSColor {
            let long = l + 0.3963377774 * a + 0.2158037573 * b
            let medium = l - 0.1055613458 * a - 0.0638541728 * b
            let short = l - 0.0894841775 * a - 1.2914855480 * b

            let longCubed = long * long * long
            let mediumCubed = medium * medium * medium
            let shortCubed = short * short * short

            let red = 4.0767416621 * longCubed - 3.3077115913 * mediumCubed + 0.2309699292 * shortCubed
            let green = -1.2684380046 * longCubed + 2.6097574011 * mediumCubed - 0.3413193965 * shortCubed
            let blue = -0.0041960863 * longCubed - 0.7034186147 * mediumCubed + 1.7076147010 * shortCubed

            return NSColor(
                srgbRed: Self.linearToSrgb(red),
                green: Self.linearToSrgb(green),
                blue: Self.linearToSrgb(blue),
                alpha: 1
            )
        }

        private static func srgbToLinear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045
                ? value / 12.92
                : CGFloat(pow(Double((value + 0.055) / 1.055), 2.4))
        }

        private static func cubeRoot(_ value: CGFloat) -> CGFloat {
            CGFloat(pow(Double(value), 1.0 / 3.0))
        }

        private static func linearToSrgb(_ value: CGFloat) -> CGFloat {
            let clamped = max(0, min(value, 1))
            if clamped <= 0.0031308 {
                return 12.92 * clamped
            }
            return 1.055 * CGFloat(pow(Double(clamped), 1.0 / 2.4)) - 0.055
        }
    }
}
