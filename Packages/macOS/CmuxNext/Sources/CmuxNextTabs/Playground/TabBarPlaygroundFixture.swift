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

    /// A model with `count` tabs, the third one selected, that opens and closes tabs like the app's.
    @MainActor func model(count: Int, style: TabStripStyle = .chrome, showsNewTabButton: Bool = true) -> TabStripModel {
        let tabs = (0..<max(1, count)).map { index in
            let sample = Self.samples[index % Self.samples.count]
            return TabItem(id: TabID("playground-\(index)"), title: sample.0, subtitle: "", icon: .symbol(sample.1))
        }
        let model = TabStripModel(tabs: tabs, selectedID: tabs[min(2, tabs.count - 1)].id, style: style,
                                  showsNewTabButton: showsNewTabButton)
        model.intentHandler = { [weak model] intent in model?.apply(intent) { TabStripDemo.makeTab() } }
        return model
    }

    /// A strip over ``model(count:style:showsNewTabButton:)`` with the current metrics changed by `adjust`.
    @MainActor func strip(count: Int, style: TabStripStyle = .chrome, showsNewTabButton: Bool = true,
                          adjust: ((inout TabStripMetrics) -> Void)? = nil) -> TabStripView {
        let strip = TabStripView(model: model(count: count, style: style, showsNewTabButton: showsNewTabButton))
        if let adjust {
            var metrics = TabStripMetrics.standard
            adjust(&metrics)
            strip.customMetrics = metrics
        }
        return strip
    }
}
