import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("Mobile task model parsing")
struct MobileTaskModelParserTests {
    private let parser = MobileTaskModelParser()

    @Test func openCodeKeepsEveryNonblankLineAndDeduplicatesInOrder() {
        let output = """

          anthropic/claude-sonnet-5
        warning: unexpected output

        opencode/big-pickle
        anthropic/claude-sonnet-5
        """
        #expect(parser.openCodeModelIDs(from: output) == [
            "anthropic/claude-sonnet-5",
            "warning: unexpected output",
            "opencode/big-pickle",
        ])
    }

    @Test func codexReadsOnlyAQuotedTopLevelModelAssignment() {
        let data = Data("""
        # model = "ignored"
        model_provider = "openai"
          model = "gpt-5.6-sol" # trailing comment
        """.utf8)
        #expect(parser.codexConfiguredModel(from: data) == "gpt-5.6-sol")
    }

    @Test(arguments: [
        "",
        "model_provider = \"openai\"",
        "model = \"\"",
        "model = gpt-5.6-sol",
        "# model = \"gpt-5.6-sol\"",
        "[profiles.work]\nmodel = \"gpt-5.6-sol\"",
    ])
    func codexReturnsNilWithoutAValidModelLine(_ text: String) {
        #expect(parser.codexConfiguredModel(from: Data(text.utf8)) == nil)
    }

    @Test func claudeReadsBedrockStyleModelIdentifier() {
        let data = Data(#"{"model":"us.anthropic.claude-opus-5","theme":"dark"}"#.utf8)
        #expect(
            parser.claudeConfiguredModel(from: data)
                == "us.anthropic.claude-opus-5"
        )
    }

    @Test(arguments: [
        Data(),
        Data("{}".utf8),
        Data(#"{"model":null}"#.utf8),
        Data(#"{"model":"  "}"#.utf8),
        Data(#"{"nested":{"model":"claude-opus-5"}}"#.utf8),
        Data("not json".utf8),
    ])
    func claudeReturnsNilWithoutATopLevelNonblankModel(_ data: Data) {
        #expect(parser.claudeConfiguredModel(from: data) == nil)
    }
}
