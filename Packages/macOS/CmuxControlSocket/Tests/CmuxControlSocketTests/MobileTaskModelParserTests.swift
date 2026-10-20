import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("Mobile task model parsing")
struct MobileTaskModelParserTests {
    private let parser = MobileTaskModelParser()

    @Test func openCodeReadsVariantsForEachExactModel() {
        let output = """
        anthropic/claude-sonnet-5
        {
          "name": "Claude Sonnet 5",
          "variants": {
            "high": {"reasoning": "high"},
            "low": {"reasoning": "low"},
            "max": {"reasoning": "max"},
            "medium": {"reasoning": "medium"},
            "none": {"reasoning": "none"},
            "xhigh": {"reasoning": "xhigh"}
          }
        }
        opencode/big-pickle
        {
          "name": "Big Pickle",
          "variants": {}
        }
        """
        #expect(parser.openCodeModels(from: output) == [
            MobileTaskModel(
                id: "anthropic/claude-sonnet-5",
                displayName: "Claude Sonnet 5",
                efforts: [
                    MobileTaskModelEffort(id: "none", displayName: "None"),
                    MobileTaskModelEffort(id: "low", displayName: "Low"),
                    MobileTaskModelEffort(id: "medium", displayName: "Medium"),
                    MobileTaskModelEffort(id: "high", displayName: "High"),
                    MobileTaskModelEffort(id: "xhigh", displayName: "Xhigh"),
                    MobileTaskModelEffort(id: "max", displayName: "Max"),
                ]
            ),
            MobileTaskModel(id: "opencode/big-pickle", displayName: "Big Pickle"),
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

    @Test func codexCatalogKeepsListedModelsWithDisplayNames() {
        let output = """
        {
          "models": [
            {
              "slug": "gpt-5.6-sol",
              "display_name": "GPT-5.6 Sol",
              "default_reasoning_level": "medium",
              "supported_reasoning_levels": [
                {"effort":"low","description":"Fast"},
                {"effort":"medium","description":"Balanced"}
              ],
              "visibility": "list"
            },
            {
              "slug": "gpt-hidden",
              "display_name": "Hidden",
              "visibility": "hidden"
            },
            {
              "slug": "gpt-5.6-luna",
              "display_name": "  ",
              "visibility": "list"
            },
            {
              "slug": "gpt-5.6-sol",
              "display_name": "Duplicate",
              "visibility": "list"
            }
          ]
        }
        """

        #expect(parser.codexModels(from: output) == [
            MobileTaskModel(
                id: "gpt-5.6-sol",
                displayName: "GPT-5.6 Sol",
                efforts: [
                    MobileTaskModelEffort(
                        id: "low",
                        displayName: "Low",
                        description: "Fast"
                    ),
                    MobileTaskModelEffort(
                        id: "medium",
                        displayName: "Medium",
                        description: "Balanced"
                    ),
                ],
                defaultEffortID: "medium"
            ),
            MobileTaskModel(id: "gpt-5.6-luna", displayName: "gpt-5.6-luna"),
        ])
    }

    @Test func claudeReadsModelSpecificEffortsWithoutSharingThem() {
        let output = #"{"type":"control_response","response":{"subtype":"success","request_id":"cmux-list-options","response":{"models":[{"value":"claude-opus","displayName":"Opus","supportedEffortLevels":["medium","high"],"defaultEffortLevel":"high"},{"value":"claude-haiku","displayName":"Haiku","supportedEffortLevels":["low"],"defaultEffortLevel":"low"}]}}}"#

        #expect(parser.claudeModels(from: output) == [
            MobileTaskModel(
                id: "claude-opus",
                displayName: "Opus",
                efforts: [
                    MobileTaskModelEffort(id: "medium", displayName: "Medium"),
                    MobileTaskModelEffort(id: "high", displayName: "High"),
                ],
                defaultEffortID: "high"
            ),
            MobileTaskModel(
                id: "claude-haiku",
                displayName: "Haiku",
                efforts: [MobileTaskModelEffort(id: "low", displayName: "Low")],
                defaultEffortID: "low"
            ),
        ])
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
