#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileMarkdown
import SwiftUI
import UIKit

/// The long-press preview of a Feed row (`FeedPeek`). Shown by the system's context menu, never
/// in a row, so it is SwiftUI: the chat's own still, or the event's markdown.
struct FeedPeekView: View {
    let item: FeedItem
    /// The chat's store when its transcript is in memory (`FeedPeek.Content.chat`).
    let chat: AgentChatStore?
    /// The event's text fills the card from its top (false while the card measures its text).
    var fills = false
    /// The event's text is taller than the card: it fades out at the bottom.
    var fades = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let chat {
                AgentChatPreview(store: chat, topInset: 0, bottomInset: 12)
            } else {
                event
            }
        }
        .background(Color.cmuxMobileBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(chat == nil ? "feed.peek.event" : "feed.peek.chat")
    }

    /// The row's place header: who, and where it happened.
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: AgentAvatarMark.fallbackSymbol(item.harness))
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Color.cmuxMobileSurfaceRaised, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.agentName).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !item.place.isEmpty {
                    Text(item.place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(FeedRowCell.relativeTime(item.createdAt, now: Date()))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The event's own words: what it answers, then its markdown.
    private var event: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let quote = item.quote, !quote.text.isEmpty {
                Text(quote.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.cmuxMobileSurfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: quote.author == .you ? .trailing : .leading)
                    .padding(.horizontal, 16)
            }
            MarkdownView(markdown: item.markdown, margin: 16)
                .padding(.horizontal, 16)
        }
        .padding(.vertical, 14)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .top)
        .clipped()
        .overlay(alignment: .bottom) {
            if fades {
                LinearGradient(colors: [Color.cmuxMobileBackground.opacity(0), Color.cmuxMobileBackground], startPoint: .top, endPoint: .bottom)
                    .frame(height: 44)
            }
        }
        .allowsHitTesting(false)
    }
}

extension FeedPeekView {
    /// The preview's view controller, sized by `FeedPeek.size` for the window it shows in.
    @MainActor
    static func controller(item: FeedItem, chat: AgentChatStore?, container: CGSize) -> UIViewController {
        let host = UIHostingController(rootView: FeedPeekView(item: item, chat: chat))
        if chat != nil {
            host.preferredContentSize = FeedPeek.size(container: container)
        } else {
            // An event's card is as tall as its text, up to the chat preview's height.
            let width = FeedPeek.size(container: container).width
            let fitting = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
            let size = FeedPeek.size(container: container, fitting: fitting)
            host.rootView.fills = true
            host.rootView.fades = fitting > size.height + 1
            host.preferredContentSize = size
        }
        host.view.backgroundColor = .cmuxMobileBackground
        return host
    }
}
#endif
