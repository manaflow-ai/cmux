import Foundation

extension SimulatorStrings {
    var accessibilityOverlay: LocalizedStringResource {
        simulatorResource("simulator.accessibility.overlay", "Live Element Overlay")
    }

    var previousPage: LocalizedStringResource {
        simulatorResource("simulator.accessibility.previousPage", "Previous")
    }

    var nextPage: LocalizedStringResource {
        simulatorResource("simulator.accessibility.nextPage", "Next")
    }

    var accessibilityTruncated: LocalizedStringResource {
        simulatorResource(
            "simulator.accessibility.truncated",
            "More elements exist beyond the bounded snapshot."
        )
    }

    func accessibilityNodeCount(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "simulator.accessibility.nodeCount",
            defaultValue: "Accessibility elements: \(count)",
            bundle: .main,
            comment: "Number of elements in the bounded Simulator accessibility snapshot."
        )
    }

    func accessibilityPage(_ page: Int, _ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "simulator.accessibility.page",
            defaultValue: "Page \(page) of \(count)",
            bundle: .main,
            comment: "Current and total pages in the Simulator accessibility element list."
        )
    }
}
