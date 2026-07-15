import Testing
@testable import CmuxFoundation

@Suite struct CmuxTemplateTests {
    @Test func parsesPriorArtPlaceholderGrammarInFirstOccurrenceOrder() {
        let template = CmuxTemplate("{{ticket}} {{apiPort=8080}} {{ticket=ignored}} {{bad.name}}")

        #expect(template.variables == [
            CmuxTemplateVariable(name: "ticket", defaultValue: nil),
            CmuxTemplateVariable(name: "apiPort", defaultValue: "8080"),
        ])
    }

    @Test func substitutesLiteralValuesAndUnescapesLiteralPlaceholders() throws {
        let template = CmuxTemplate(#"https://example.test/{{ticket}}/\{{upstream}}?q={{query}}"#)
        let resolver = CmuxTemplateResolver(
            explicitValues: ["ticket": "BERKS-87", "query": "a/b & c"]
        )

        #expect(try resolver.resolve(template) == "https://example.test/BERKS-87/{{upstream}}?q=a/b & c")
    }

    @Test func resolvesWithDocumentedPrecedence() throws {
        let templates = [
            CmuxTemplate("{{explicit}} {{definition}} {{workspaceEnv}} {{processEnv}} {{inline=inline-default}}"),
        ]
        let resolver = CmuxTemplateResolver(
            explicitValues: [
                "explicit": "explicit-value",
                "definition": "explicit-wins",
            ],
            definitionValues: [
                "definition": "definition-value",
                "workspaceEnv": "definition-wins",
            ],
            workspaceEnvironment: [
                "workspaceEnv": "workspace-value",
                "processEnv": "workspace-wins",
            ],
            processEnvironment: [
                "processEnv": "process-value",
                "inline": "process-wins",
            ]
        )

        #expect(try resolver.resolve(templates[0])
            == "explicit-value explicit-wins definition-wins workspace-wins process-wins")
    }

    @Test func reportsAllMissingVariablesOnceInTraversalOrder() {
        let resolver = CmuxTemplateResolver(processEnvironment: [:])

        #expect(throws: CmuxTemplateResolutionError.missingVariables(["ticket", "apiPort", "vitePort"])) {
            try resolver.resolve([
                CmuxTemplate("{{ticket}} {{apiPort}}"),
                CmuxTemplate("{{ticket}} {{vitePort}}"),
            ])
        }
    }

    @Test func ignoresInvalidAndEscapedPlaceholderFormsWhenCheckingMissingValues() throws {
        let resolver = CmuxTemplateResolver(processEnvironment: [:])

        #expect(try resolver.resolve(CmuxTemplate(#"{{bad.name}} {{1port}} \{{literal}}"#))
            == "{{bad.name}} {{1port}} {{literal}}")
    }

    @Test func malformedPlaceholderDoesNotHideNestedValidPlaceholder() throws {
        let resolver = CmuxTemplateResolver(explicitValues: ["ticket": "BERKS-87"])
        let resolved = try resolver.resolve(CmuxTemplate("{{bad{{ticket}}"))

        #expect(resolved == "{{badBERKS-87")
    }

    @Test func parameterInputsPreserveOrderAndExposeEditableSuggestedValues() {
        let resolver = CmuxTemplateResolver(
            definitionValues: ["ticket": "CMUX-8059"],
            workspaceEnvironment: ["region": "workspace-region"],
            processEnvironment: ["owner": "austin"]
        )

        #expect(resolver.parameterInputs(for: [
            CmuxTemplate("{{ticket}} {{missing}}"),
            CmuxTemplate("{{region}} {{owner}} {{port=4100}} {{ticket=ignored}}"),
        ]) == [
            CmuxTemplateParameterInput(name: "ticket", suggestedValue: "CMUX-8059"),
            CmuxTemplateParameterInput(name: "missing", suggestedValue: nil),
            CmuxTemplateParameterInput(name: "region", suggestedValue: "workspace-region"),
            CmuxTemplateParameterInput(name: "owner", suggestedValue: "austin"),
            CmuxTemplateParameterInput(name: "port", suggestedValue: "4100"),
        ])
    }
}
