import Testing
@testable import CMUXAgentLaunch

@Suite
struct WorkstreamQuestionPromptParsingTests {
    @Test("parses nested questions with rich options")
    func parsesNestedQuestions() throws {
        let parsed = WorkstreamQuestionPrompt.parse(toolInputJSON: #"""
        {
          "questions": [{
            "id": "q-choice",
            "header": "Approach",
            "question": "Which one?",
            "multiSelect": true,
            "options": [{"id":"fast","label":"Fast","description":"Ship now"}]
          }]
        }
        """#)

        let question = try #require(parsed.first)
        #expect(question.id == "q-choice")
        #expect(question.header == "Approach")
        #expect(question.prompt == "Which one?")
        #expect(question.multiSelect)
        #expect(question.options == [.init(id: "fast", label: "Fast", description: "Ship now")])
    }

    @Test("parses flat questions and defaults multi-select to false")
    func parsesFlatQuestion() throws {
        let parsed = WorkstreamQuestionPrompt.parse(toolInputJSON: #"""
        {
          "prompt": "Choose",
          "options": ["Alpha", "Beta"]
        }
        """#)

        let question = try #require(parsed.first)
        #expect(question.id == "q0")
        #expect(question.prompt == "Choose")
        #expect(!question.multiSelect)
        #expect(question.options == [
            .init(id: "opt0", label: "Alpha"),
            .init(id: "opt1", label: "Beta"),
        ])
    }

    @Test("parses boolean confirmations into a yes/no primitive")
    func parsesBooleanConfirmation() throws {
        let parsed = WorkstreamQuestionPrompt.parse(toolInputJSON: #"""
        {
          "type":"boolean",
          "prompt":"Apply the migration?",
          "default":true
        }
        """#)

        let question = try #require(parsed.first)
        #expect(question.inputType == .boolean)
        #expect(question.options.map(\.id) == ["yes", "no"])
        #expect(question.defaultValue == "1")
    }

    @Test("parses JSON schema elicitation fields")
    func parsesFormSchema() throws {
        let parsed = WorkstreamQuestionPrompt.parse(toolInputJSON: #"""
        {
          "schema": {
            "type":"object",
            "properties": {
              "branch": {"type":"string", "description":"Branch name"},
              "count": {"type":"integer", "default":2}
            },
            "required":["branch"]
          }
        }
        """#)

        #expect(parsed.map(\.id) == ["branch", "count"])
        #expect(parsed[0].inputType == .text)
        #expect(parsed[0].required == true)
        #expect(parsed[0].placeholder == "Branch name")
        #expect(parsed[1].inputType == .integer)
        #expect(parsed[1].defaultValue == "2")
    }

    @Test("parses Codex user-input metadata and MCP elicitation aliases")
    func parsesCodexAndMCPMetadata() throws {
        let parsed = WorkstreamQuestionPrompt.parse(toolInputJSON: #"""
        {
          "questions": [{
            "id": "secret",
            "header": "Credentials",
            "question": "Token",
            "isSecret": true,
            "isOther": false,
            "options": []
          }]
        }
        """#)

        let question = try #require(parsed.first)
        #expect(question.inputType == .secret)
        #expect(question.allowsOther == false)

        let schemaFields = WorkstreamQuestionPrompt.parse(toolInputJSON: #"""
        {
          "message": "Authorize the MCP server",
          "requestedSchema": {
            "type": "object",
            "properties": {
              "callback": {"type": "string", "format": "uri"}
            },
            "required": ["callback"]
          }
        }
        """#)
        let field = try #require(schemaFields.first)
        #expect(field.id == "callback")
        #expect(field.inputType == .url)
        #expect(field.required == true)
    }

    @Test("parses JSON schema enums as bounded single and multiple choices")
    func parsesSchemaEnums() throws {
        let parsed = WorkstreamQuestionPrompt.parse(toolInputJSON: #"""
        {
          "requestedSchema": {
            "type": "object",
            "properties": {
              "mode": {"type":"string", "enum":["Fast", "Safe"], "default":"Safe"},
              "targets": {"type":"array", "items":{"type":"string", "enum":["iOS", "macOS"]}}
            },
            "required": ["mode", "targets"]
          }
        }
        """#)

        let mode = try #require(parsed.first { $0.id == "mode" })
        #expect(mode.inputType == .choice)
        #expect(mode.multiSelect == false)
        #expect(mode.options.map(\.label) == ["Fast", "Safe"])
        #expect(mode.defaultValue == "opt1")
        #expect(mode.allowsOther == false)

        let targets = try #require(parsed.first { $0.id == "targets" })
        #expect(targets.inputType == .choice)
        #expect(targets.multiSelect)
        #expect(targets.options.map(\.label) == ["iOS", "macOS"])
        #expect(targets.allowsOther == false)
    }

    @Test("parses OpenCode multiple-choice and custom-answer aliases")
    func parsesOpenCodeQuestionAliases() throws {
        let parsed = WorkstreamQuestionPrompt.parse(toolInputJSON: #"""
        {
          "questions": [{
            "header": "Targets",
            "question": "Which targets?",
            "multiple": true,
            "custom": false,
            "options": [{"label":"iOS","description":"Phone"},{"label":"macOS","description":"Desktop"}]
          }]
        }
        """#)

        let question = try #require(parsed.first)
        #expect(question.multiSelect)
        #expect(question.allowsOther == false)
        #expect(question.options.map(\.label) == ["iOS", "macOS"])
    }

    @Test("parses URL-mode and secret elicitation fields without exposing false controls")
    func parsesExternalAndSecretFields() throws {
        let external = WorkstreamQuestionPrompt.parse(toolInputJSON: #"""
        {
          "fields": [{
            "id": "continue",
            "prompt": "Finish authorization in the browser",
            "input_type": "external",
            "required": false,
            "external_url": "https://example.com/authorize"
          }]
        }
        """#)
        let link = try #require(external.first)
        #expect(link.inputType == .external)
        #expect(link.externalURL == "https://example.com/authorize")

        let schema = WorkstreamQuestionPrompt.parse(toolInputJSON: #"""
        {
          "schema": {
            "type": "object",
            "properties": {
              "email": {"type":"string", "format":"email"},
              "token": {"type":"string", "format":"password"}
            }
          }
        }
        """#)
        #expect(schema.first { $0.id == "email" }?.inputType == .email)
        #expect(schema.first { $0.id == "token" }?.inputType == .secret)
    }

    @Test("parses current MCP titled enums and validation constraints")
    func parsesCurrentMCPSchemaPrimitives() throws {
        let parsed = WorkstreamQuestionPrompt.parse(toolInputJSON: #"""
        {
          "requestedSchema": {
            "type": "object",
            "properties": {
              "mode": {
                "type": "string",
                "oneOf": [
                  {"const":"fast","title":"Fast path"},
                  {"const":"safe","title":"Safe path"}
                ],
                "default": "safe"
              },
              "targets": {
                "type": "array",
                "items": {"anyOf":[
                  {"const":"ios","title":"iOS"},
                  {"const":"mac","title":"macOS"}
                ]},
                "minItems": 1,
                "maxItems": 2
              },
              "count": {"type":"integer","minimum":1,"maximum":5},
              "name": {"type":"string","minLength":2,"maxLength":12},
              "when": {"type":"string","format":"date-time"}
            }
          }
        }
        """#)

        let mode = try #require(parsed.first { $0.id == "mode" })
        #expect(mode.options == [
            .init(id: "fast", label: "Fast path"),
            .init(id: "safe", label: "Safe path"),
        ])
        #expect(mode.defaultValue == "safe")

        let targets = try #require(parsed.first { $0.id == "targets" })
        #expect(targets.multiSelect)
        #expect(targets.options.map(\.id) == ["ios", "mac"])
        #expect(targets.minSelections == 1)
        #expect(targets.maxSelections == 2)

        let count = try #require(parsed.first { $0.id == "count" })
        #expect(count.inputType == .integer)
        #expect(count.minimum == 1)
        #expect(count.maximum == 5)

        let name = try #require(parsed.first { $0.id == "name" })
        #expect(name.minLength == 2)
        #expect(name.maxLength == 12)
        #expect(parsed.first { $0.id == "when" }?.inputType == .dateTime)
    }
}
