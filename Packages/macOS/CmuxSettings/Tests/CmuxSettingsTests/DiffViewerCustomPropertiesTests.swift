import Testing
@testable import CmuxSettings

struct DiffViewerCustomPropertiesTests {
    @Test func keepsFirstValidValueForEachProperty() {
        let properties = DiffViewerCustomProperties(layers: [
            ["--cmux-diff-accent": "  #ABCDEF\n", "--cmux-diff-error": "red"],
            ["--cmux-diff-accent": "#123456", "--cmux-diff-error": "#654321"],
            ["--cmux-diff-error": "#ffffff", "--cmux-diff-renamed-light": "#012345"]
        ])
        #expect(properties.values == [
            "--cmux-diff-accent": "#abcdef",
            "--cmux-diff-error": "#654321",
            "--cmux-diff-renamed-light": "#012345"
        ])
    }

    @Test func rejectsUnsupportedNamesAndNonColorValues() {
        let properties = DiffViewerCustomProperties(layers: [[
            "--cmux-diff-accent": "#abc",
            "--cmux-diff-error": "123456",
            "--cmux-diff-renamed-light": "#12zz56",
            "--cmux-diff-renamed-dark": 123456,
            "--cmux-diff-addition-fg-light": "url(https://example.com)",
            "--cmux-diff-addition-fg-dark": "#123456;display:none",
            "--cmux-diff-deletion-fg-light": "#12345678",
            "--cmux-diff-deletion-fg-dark": "#１２３４５６",
            "--cmux-diff-bg-light": "#ffffff",
            "color": "#ffffff"
        ]])
        #expect(properties.values.isEmpty)
    }

    @Test(arguments: [
        "--cmux-diff-accent", "--cmux-diff-error",
        "--cmux-diff-renamed-light", "--cmux-diff-renamed-dark",
        "--cmux-diff-addition-fg-light", "--cmux-diff-addition-fg-dark",
        "--cmux-diff-deletion-fg-light", "--cmux-diff-deletion-fg-dark"
    ])
    func acceptsSupportedProperty(_ name: String) {
        #expect(DiffViewerCustomProperties(layers: [[name: "#123456"]]).values == [name: "#123456"])
    }
}
