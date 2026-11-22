import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (the Debug menu): how a tab's hover card first shows (Leo 2026-11-07: "do we want to make it, like,
/// morph together with the tab? Or would that be a bit, like, awkward? ... I wanted to have goo, right? Like the things
/// morph into each other and have that cool little animation where it's like that water surface tension thing"), and how
/// it moves to the next tab (Leo 2026-11-18: "the hover preview bounces for some reason"). Every row is the real strip
/// with agent and terminal tabs; hover a tab to see its card enter, then move to the next tab. The card is as wide as a
/// tab at its widest, on the tab's leading edge, with plain rows under the title. The fade ships, switching in place:
/// grown out of the tab or gliding to the next one, it read as a bounce. The move rows enter with the shipped fade.
struct HoverCardEntrancePlaygroundVariants {
    private let fixture = TabBarPlaygroundFixture()

    var all: [TabBarPlaygroundVariant] {
        [
            variant(String(localized: "tabs.playground.hoverCard.morph", defaultValue: "Grows out of the tab, settling like a drop",
                           bundle: .localizedModule), .morph),
            variant(String(localized: "tabs.playground.hoverCard.slide", defaultValue: "Fades in while it slides down from the tab",
                           bundle: .localizedModule), .slide),
            variant(String(localized: "tabs.playground.hoverCard.fade", defaultValue: "Fades in where it rests", bundle: .localizedModule), .fade, shipped: true),
            variant(String(localized: "tabs.playground.hoverCard.retarget.jump", defaultValue: "Switches to the next tab in place",
                           bundle: .localizedModule), .fade, retarget: .jump, shipped: true),
            variant(String(localized: "tabs.playground.hoverCard.retarget.crossfade",
                           defaultValue: "Switches in place, its content cross-fading", bundle: .localizedModule), .fade, retarget: .crossfade),
            variant(String(localized: "tabs.playground.hoverCard.retarget.glide", defaultValue: "Glides to the next tab", bundle: .localizedModule),
                    .fade, retarget: .glide),
        ]
    }

    private func variant(_ name: String, _ entrance: HoverCardEntrance, retarget: HoverCardRetarget = .jump,
                         shipped: Bool = false) -> TabBarPlaygroundVariant {
        let fixture = fixture
        return TabBarPlaygroundVariant(name: name, isShipped: shipped) { count in
            let model = fixture.model(count: count)
            let now = Date()
            // An agent chat and a terminal in turn, each with the facts its card shows.
            model.tabs = model.tabs.enumerated().map { index, tab in
                var tab = tab
                tab.subtitle = "~/Projects/cmux"
                tab.hover = index.isMultiple(of: 2)
                    ? TabHoverFacts(kind: .agentChat, activity: .idle, since: now.addingTimeInterval(-22), model: "claude-opus-5-5")
                    : TabHoverFacts(kind: .terminal, activity: .running, since: now.addingTimeInterval(-95), branch: "main")
                return tab
            }
            let strip = TabStripView(model: model)
            strip.hoverCard.entrance = entrance
            strip.hoverCard.retarget = retarget
            return TabBarPlaygroundBar(strip: strip)
        }
    }
}
