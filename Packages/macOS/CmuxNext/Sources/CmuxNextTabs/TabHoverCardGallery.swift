#if DEBUG
public import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextResources

/// DEBUG ONLY: the tab hover card in each of its kinds over fixture data, for the hover card
/// gallery (`debug.hover_cards {gallery}`, HoverCardGallery, the macOS tour's `hover-card` shots). No thumbnails: the
/// rows are what the gallery shows.
public struct TabHoverCardGallery {
    public init() {}
    @MainActor public static func cards(now: Date = Date()) -> [(name: String, view: NSView)] {
        var running = TabItem(id: TabID("gallery-terminal"), title: "cargo build --release", subtitle: "~/Projects/cmux",
                              icon: .symbol("terminal"), isBusy: true)
        running.hover = TabHoverFacts(kind: .terminal, activity: .running, since: now.addingTimeInterval(-12), branch: "main")
        var failed = TabItem(id: TabID("gallery-terminal-failed"), title: "swift test", subtitle: "~/Projects/cmux",
                             icon: .symbol("terminal"), status: .failure)
        failed.hover = TabHoverFacts(kind: .terminal, branch: "feat/shared-hover-card")
        var page = TabItem(id: TabID("gallery-browser"), title: "cmux docs", subtitle: "https://cmux.com/docs/getting-started",
                           icon: favicon().map(TabIcon.image) ?? .icon(.browser))
        page.hover = TabHoverFacts(kind: .browser)
        var blank = TabItem(id: TabID("gallery-blank"), title: "about:blank", subtitle: "about:blank", icon: .icon(.browser))
        blank.hover = TabHoverFacts(kind: .browser)
        var chat = TabItem(id: TabID("gallery-chat"), title: "Make the hover cards look like Codex's", subtitle: "~/Projects/cmux",
                           icon: .icon(.agentChat))
        chat.indicator = .working
        chat.hover = TabHoverFacts(kind: .agentChat, activity: .working, since: now.addingTimeInterval(-185), model: "gpt-6.1-sol")
        let samples: [(TabItem, [Double], UInt64)] = [
            (running, [0.6, 1.2, 2.4, 3.1, 2.8, 3.4], 840), (failed, [], 0), (page, [0.05, 0.1, 0.02], 106), (blank, [], 0),
            (chat, [0.2, 0.3, 0.25], 46),
        ]
        return [("Terminal running", 0), ("Terminal failed", 1), ("Browser tab", 2), ("Blank page", 3), ("Agent chat", 4)].map { name, index in
            let (item, cpu, megabytes) = samples[index]
            let card = TabHoverCardView()
            card.configure(.tab(item))
            card.setThumbnailVisible(false)
            for value in cpu {
                let usage = ResourceUsage(cpu: value, memoryBytes: megabytes << 20)
                card.setResources(ResourceReport(tabs: [TabResourceReport(id: item.id.rawValue, title: item.title, kind: .terminal, usage: usage,
                                                                         processCount: 1, sharedWithTabs: 0, available: true)],
                                                 total: usage, processCount: 1))
            }
            return (name, HoverCardGalleryHost(body: card, cornerRadius: Metrics.tabCornerRadius) { [weak card] in card?.applyColors() })
        }
    }

    /// A small rounded-square favicon in the cmux blue, drawn here (no network in a gallery).
    private static func favicon() -> TabImage? {
        let side = 32
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0.22, green: 0.45, blue: 0.95, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerWidth: 7, cornerHeight: 7, transform: nil))
        context.fillPath()
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 9, y: 9, width: 14, height: 14))
        return context.makeImage().map(TabImage.init)
    }
}
#endif
