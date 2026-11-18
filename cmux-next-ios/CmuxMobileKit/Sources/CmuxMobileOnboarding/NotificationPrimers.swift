#if os(iOS)
import CmuxMobileDesign
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The notifications page's three versions. `list` ships; `preview` and
/// `actions` are the alternatives to compare (Aziz 2026-11-18), switched on the
/// page in DEBUG builds or at launch with `-cmux-mobile-notifications-primer NAME`.
public enum NotificationsPrimer: String, CaseIterable, Sendable {
    /// "Know when an agent needs you": a bell and three kinds of alerts.
    case list
    /// "Your agents tap you on the shoulder": a stack of real-looking alerts.
    case preview
    /// "Answer from the lock screen": one permission request with its actions.
    case actions

    /// The switcher's label.
    public var label: String {
        switch self {
        case .list: "A · List"
        case .preview: "B · Preview"
        case .actions: "C · Actions"
        }
    }

    /// The version a launch argument picks, if any.
    public static func choice(in arguments: [String]) -> NotificationsPrimer? {
        guard let index = arguments.firstIndex(of: "-cmux-mobile-notifications-primer"),
              arguments.indices.contains(index + 1) else { return nil }
        return NotificationsPrimer(rawValue: arguments[index + 1])
    }

    static var launchChoice: NotificationsPrimer? { choice(in: ProcessInfo.processInfo.arguments) }
}

/// What a cmux alert looks like on the lock screen, drawn in the app (not a real
/// notification): the app mark, the sender, the time, a title and a body.
struct NotificationMock: View {
    let sender: String
    let time: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppMark()
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sender)
                        .font(theme.type.meta.weight(.semibold))
                        .foregroundStyle(theme.colors.label)
                    Spacer(minLength: 6)
                    Text(time)
                        .font(theme.type.legal)
                        .foregroundStyle(theme.colors.label2)
                }
                Text(title)
                    .font(theme.type.meta.weight(.semibold))
                    .foregroundStyle(theme.colors.label)
                Text(message)
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.label)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.surfaceRaised.color, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The cmux mark as on the home screen: a blue chevron on a dark rounded square.
private struct AppMark: View {
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 34

    var body: some View {
        Image(systemName: "chevron.right")
            .font(theme.type.meta.weight(.heavy))
            // The home-screen icon's gradient (WelcomeArt.iconGradient) on black, in both modes.
            .foregroundStyle(LinearGradient(colors: [Color(hex: "#06CDFE"), Color(hex: "#2AA0F9"), Color(hex: "#5170F3")],
                                            startPoint: .top, endPoint: .bottom))
            .frame(width: min(size, 48), height: min(size, 48))
            .background(Color.black, in: .rect(cornerRadius: min(size, 48) * 0.24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: min(size, 48) * 0.24, style: .continuous)
                .strokeBorder(theme.colors.separator.color, lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// Version B's header: three alerts stacked as the lock screen stacks them, each
/// one a kind cmux sends (a permission request, a finished task, a failure).
struct NotificationStackPreview: View {
    var body: some View {
        VStack(spacing: 8) {
            NotificationMock(sender: "Claude · cmux", time: "now",
                             title: "Allow cargo test -p cmux-mobile-link?",
                             message: "Asks to run this in cmux-next-ios.")
            NotificationMock(sender: "Codex · api-server", time: "4m ago",
                             title: "Finished",
                             message: "Fixed the 2 failing auth tests. The diff is ready to review.")
                .opacity(0.85)
            NotificationMock(sender: "Chief", time: "12m ago",
                             title: "Build failed on main",
                             message: "Swift compile error in RootView.swift. Want me to fix it?")
                .opacity(0.65)
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Examples of cmux notifications"))
    }
}

/// Version C's header: one permission request pressed open, with the actions
/// cmux puts on it (Allow once, Always allow, Deny; `PushActions`).
struct NotificationActionsPreview: View {
    var body: some View {
        VStack(spacing: 8) {
            NotificationMock(sender: "Claude · cmux", time: "now",
                             title: "Allow git push origin feat-login?",
                             message: "Asks to run this in cmux-next-ios.")
            VStack(spacing: 0) {
                ActionRow(title: "Allow once", symbol: "checkmark")
                Divider().overlay(theme.colors.separator.color)
                ActionRow(title: "Always allow", symbol: "checkmark.seal")
                Divider().overlay(theme.colors.separator.color)
                ActionRow(title: "Deny", symbol: "xmark", destructive: true)
            }
            .background(theme.colors.surfaceRaised.color, in: .rect(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("A permission request with Allow once, Always allow and Deny"))
    }
}

private struct ActionRow: View {
    let title: String
    let symbol: String
    var destructive = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: symbol).accessibilityHidden(true)
        }
        .font(theme.type.rowSubtitle)
        .foregroundStyle(destructive ? theme.colors.dangerText.color : theme.colors.label.color)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
#endif
