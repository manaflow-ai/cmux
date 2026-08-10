import Testing
@testable import CmuxBrowser

@Suite
struct BrowserDesignModePromptFormatterAlignmentTests {
    @Test func rejectsScreenshotPathsThatDoNotAlignWithSelections() {
        func selection(_ selector: String) -> BrowserDesignModeSelection {
            BrowserDesignModeSelection(
                selector: selector,
                selectors: [selector],
                tagName: "div",
                domSnippet: "<div></div>",
                textContent: "",
                textEditable: false,
                bounds: BrowserDesignModeRect(x: 0, y: 0, width: 10, height: 10),
                viewport: BrowserDesignModeViewport(width: 100, height: 100),
                computedStyles: [:]
            )
        }
        let first = selection("#first")
        let second = selection("#second")
        let context = BrowserDesignModePromptContext(
            pageURL: "https://example.com",
            snapshot: BrowserDesignModeSnapshot(
                revision: 1,
                enabled: true,
                selection: second,
                selections: [first, second],
                edits: [],
                cssDiff: ""
            ),
            screenshotPaths: [
                nil,
                "/tmp/cmux-browser-design-mode/first.png",
                "/tmp/cmux-browser-design-mode/second.png",
            ],
            requestedChange: "Compare these elements.",
            pageScreenshotPath: "/tmp/cmux-browser-design-mode/page.png"
        )

        let prompt = BrowserDesignModePromptFormatter().format(
            context,
            contextJSONPath: "/tmp/cmux-browser-design-mode/context.json"
        )

        #expect(prompt.isEmpty)
    }
}
