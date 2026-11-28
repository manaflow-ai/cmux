import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (the Debug menu): the tabs every playground row shows: real titles from a working session (terminals,
/// agents, pages), so a crowded strip reads as it does in the app. Each row gets its own model, so
/// a click, a close or a new tab in one row leaves the others as they are.
struct TabBarPlaygroundFixture {
    private static let samples: [(String, String)] = [
        ("cmux-next", "terminal"), ("claude: crowded tab titles", "sparkles"), ("Helper 1", "terminal"),
        ("Helper 2", "terminal"), ("npm run dev", "shippingbox"), ("cmux.com/next", "globe"),
        ("feat-cmux-next", "arrow.triangle.branch"), ("TabCell.swift", "doc.text"), ("htop", "gauge.with.dots.needle.33percent"),
        ("GitHub: manaflow-ai/cmux", "globe"), ("codex: perf lead", "sparkles"), ("zsh", "terminal"),
    ]
    /// Pinned tabs as in Lawrence msg 20243's shot: a doc and an image, icon only.
    private static let pinnedSamples: [(String, String)] = [
        ("Design doc", "doc.text"), ("Screenshot", "photo"), ("Calendar", "calendar"),
    ]

    /// A model with `count` tabs, the third one selected (with two pinned tabs, the first normal one), that opens and closes tabs like the app's.
    /// `pinned`: how many of the first tabs are pinned icon-only tabs (a doc, an image, ...).
    /// `agentMarks`: every other tab is a working agent on another machine (a spinner and a machine badge), as a
    /// strip of agent chats is (Leo 2026-11-27, "why dont your tabs have any names/letters showing up?").
    @MainActor func model(count: Int, pinned: Int = 0, style: TabStripStyle = .chrome, showsNewTabButton: Bool = true,
                          agentMarks: Bool = false) -> TabStripModel {
        let tabs = (0..<max(1, count)).map { index in
            if index < pinned {
                let sample = Self.pinnedSamples[index % Self.pinnedSamples.count]
                return TabItem(id: TabID("playground-\(index)"), title: sample.0, subtitle: "", icon: .symbol(sample.1), isPinned: true)
            }
            let sample = Self.samples[(index - pinned) % Self.samples.count]
            var item = TabItem(id: TabID("playground-\(index)"), title: sample.0, subtitle: "", icon: .symbol(sample.1))
            if agentMarks, index % 2 == 1 {
                item.indicator = .working(progress: nil)
                item.machineBadge = "gcp"
            }
            return item
        }
        let model = TabStripModel(tabs: tabs, selectedID: tabs[min(2, tabs.count - 1)].id, style: style,
                                  showsNewTabButton: showsNewTabButton)
        model.intentHandler = { [weak model] intent in model?.apply(intent) { TabStripDemo.makeTab() } }
        return model
    }

    /// A strip over ``model(count:style:showsNewTabButton:)`` with the current metrics changed by `adjust`.
    @MainActor func strip(count: Int, pinned: Int = 0, style: TabStripStyle = .chrome, showsNewTabButton: Bool = true,
                          agentMarks: Bool = false, adjust: ((inout TabStripMetrics) -> Void)? = nil) -> TabStripView {
        let strip = TabStripView(model: model(count: count, pinned: pinned, style: style, showsNewTabButton: showsNewTabButton,
                                              agentMarks: agentMarks))
        if let adjust {
            var metrics = TabStripMetrics.standard
            adjust(&metrics)
            strip.customMetrics = metrics
        }
        return strip
    }
}
