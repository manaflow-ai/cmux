import CmuxConversationGeometry
import CmuxMobileNotifications
import SwiftUI
import UIKit

/// The Messages look of the app's Chief chat (CmuxConversation), drawn
/// without that module (it pulls the chat model, Markdown and WebKit; the
/// extension has a tight memory budget). Colors and metrics are
/// ConversationTheme's and ConversationHeaderView's; the bubble outline is
/// the same `ConversationBubbleGeometry` path.
enum ConversationLook {
    /// ConversationTheme.incomingBubble.
    static let incomingBubble = Color(uiColor: UIColor(dynamicProvider: { @Sendable traits in
        if traits.accessibilityContrast == .high {
            return traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.188, green: 0.188, blue: 0.201, alpha: 1)
                : UIColor(red: 0.873, green: 0.873, blue: 0.880, alpha: 1)
        }
        return traits.userInterfaceStyle == .dark
            ? UIColor(red: 38 / 255, green: 38 / 255, blue: 41 / 255, alpha: 1)
            : UIColor(red: 233 / 255, green: 233 / 255, blue: 235 / 255, alpha: 1)
    }))

    /// ConversationTheme.outgoingBubble (the flat service color the screen
    /// gradient settles on at the composer).
    static let outgoingBubble = Color(uiColor: UIColor(dynamicProvider: { @Sendable traits in
        guard traits.accessibilityContrast == .high else { return UIColor.systemBlue.resolvedColor(with: traits) }
        return traits.userInterfaceStyle == .dark
            ? UIColor(red: 0, green: 98 / 255, blue: 219 / 255, alpha: 1)
            : UIColor(red: 0, green: 105 / 255, blue: 233 / 255, alpha: 1)
    }))

    /// ConversationTheme.monogramGradient, top to bottom.
    static let monogramGradient = [
        Color(uiColor: UIColor(dynamicProvider: { @Sendable in $0.userInterfaceStyle == .dark
            ? UIColor(red: 87 / 255, green: 83 / 255, blue: 104 / 255, alpha: 1)
            : UIColor(red: 169 / 255, green: 194 / 255, blue: 226 / 255, alpha: 1) })),
        Color(uiColor: UIColor(dynamicProvider: { @Sendable in $0.userInterfaceStyle == .dark
            ? UIColor(red: 48 / 255, green: 38 / 255, blue: 73 / 255, alpha: 1)
            : UIColor(red: 115 / 255, green: 127 / 255, blue: 185 / 255, alpha: 1) })),
    ]
    static let monogramFontScale: CGFloat = 0.472

    /// ConversationTheme.bubbleFont: body with tight leading.
    static var bubbleFont: UIFont {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
        return UIFont(descriptor: descriptor.withSymbolicTraits(.traitTightLeading) ?? descriptor, size: 0)
    }

    static var isAccessibilitySize: Bool { bubbleFont.pointSize >= 28 }
    static var bubbleVerticalPadding: CGFloat { isAccessibilitySize ? 12 : 10 }
    static var bubbleHorizontalPadding: CGFloat { isAccessibilitySize ? 50.0 / 3 : 14 }
    /// Half a single-line bubble's height (ConversationTheme.bubbleCornerRadius).
    static var bubbleCornerRadius: CGFloat { (bubbleFont.lineHeight + 2 * bubbleVerticalPadding) / 2 }

    /// The header's name: bold, following Dynamic Type between Large and XXL (ConversationHeaderView.nameFont).
    static var nameFont: UIFont {
        let headline = UIFontMetrics(forTextStyle: .headline).scaledValue(for: 17)
        return .systemFont(ofSize: ConversationHeaderGeometry.namePointSize(scaled: headline), weight: .bold)
    }
}

/// Chief's avatar: its text (an emoji or initials) in white on the Contacts
/// monogram gradient, as Home, the chat header and the details page draw it.
struct MonogramAvatar: View {
    let text: String
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: ConversationLook.monogramGradient, startPoint: .top, endPoint: .bottom))
            .frame(width: diameter, height: diameter)
            .overlay {
                Text(text)
                    .font(Font(UIFont.systemFont(ofSize: diameter * ConversationLook.monogramFontScale, weight: .semibold)))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, diameter * 0.08)
            }
            .accessibilityHidden(true)
    }
}

/// The Chief chat's header: the avatar over a glass name capsule with
/// Messages' compact chevron, and the Mac it runs on under them.
struct ChiefHeader: View {
    let name: String
    let avatar: String
    let mac: String?
    /// Messages' compact header: a small avatar beside the name and the Mac.
    var compact = false

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mac.map { String(localized: "\(name) on \($0)") } ?? name)
        .accessibilityIdentifier("cmux.push.chief.header")
    }

    private var compactBody: some View {
        HStack(spacing: 10) {
            MonogramAvatar(text: avatar, diameter: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Font(ConversationLook.nameFont)).lineLimit(1)
                if let mac { Text(mac).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
    }

    private var fullBody: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .top) {
                // ConversationHeaderView: a 60 pt avatar, the capsule 55 pt below its top, the avatar over it.
                HStack(spacing: 5.9) {
                    Text(name).font(Font(ConversationLook.nameFont)).lineLimit(1)
                    Image(systemName: "chevron.compact.forward")
                        .font(.system(.body, weight: .heavy))
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 13).padding(.trailing, 10.9)
                .frame(minHeight: 97.0 / 3)
                .glassEffect(.regular, in: Capsule())
                .padding(.top, 55)
                MonogramAvatar(text: avatar, diameter: 60)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
            }
            if let mac {
                Text(mac).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The Messages bubble outline (ChatKit's continuous corners and iOS tail),
/// the shape the app's transcript fills. The tail drops below the bounds.
struct BubbleOutline: Shape {
    var side: ConversationBubbleGeometry.Side
    var tail: Bool
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2)
        return Path(ConversationBubbleGeometry.path(in: rect, side: side, tail: tail, radius: r, tailWidth: 0,
                                                    tailDrop: ConversationBubbleGeometry.iOSTailDrop(radius: r)))
    }
}

/// The history as the app's transcript draws it: incoming gray on the left,
/// the person's blue on the right, a tail on the last bubble of each run,
/// 4 pt inside a run and 10 pt between runs.
struct TranscriptPreview: View {
    let messages: [PushSnapshot.Message]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                let next = index + 1 < messages.count ? messages[index + 1] : nil
                let endsRun = next.map { side($0) != side(message) } ?? true
                MessageBubble(message: message, tail: endsRun)
                    .padding(.bottom, next == nil ? ConversationBubbleGeometry.iOSTailDrop(radius: ConversationLook.bubbleCornerRadius) : (endsRun ? 10 : 4))
            }
        }
        .accessibilityIdentifier("cmux.push.history")
    }

    private func side(_ message: PushSnapshot.Message) -> ConversationBubbleGeometry.Side {
        message.role == .user ? .trailing : .leading
    }
}

struct MessageBubble: View {
    let message: PushSnapshot.Message
    let tail: Bool

    var body: some View {
        let mine = message.role == .user
        HStack(spacing: 0) {
            if mine { Spacer(minLength: 48) }
            Text(message.text)
                .font(Font(ConversationLook.bubbleFont))
                .foregroundStyle(mine ? Color.white : (message.role == .system ? Color.red : Color.primary))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, ConversationLook.bubbleHorizontalPadding)
                .padding(.vertical, ConversationLook.bubbleVerticalPadding - 2)
                .frame(minHeight: 2 * ConversationLook.bubbleCornerRadius)
                .background {
                    BubbleOutline(side: mine ? .trailing : .leading, tail: tail, radius: ConversationLook.bubbleCornerRadius)
                        .fill(mine ? ConversationLook.outgoingBubble : ConversationLook.incomingBubble)
                }
            if !mine { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mine ? String(localized: "You: \(message.text)") : message.text)
    }
}
