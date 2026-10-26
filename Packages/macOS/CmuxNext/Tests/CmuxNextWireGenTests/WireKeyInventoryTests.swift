import Foundation
import Testing
@testable import CmuxNextWireGen

private func json(_ text: String) throws -> SchemaJSON {
    try JSONDecoder().decode(SchemaJSON.self, from: Data(text.utf8))
}

/// WireKeyInventory (p05-ipc task 021): where the generated request coder's keys differ
/// from the old snake-case encoder's, through inline and named types, for tasks 030-043.
@Suite struct WireKeyInventoryTests {
    private static func liveInventory() throws -> WireKeyInventory {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/sdk-schema.json"))
        return try RequestSchema(sdkSchema: data).inventory
    }

    /// Every keyed wire name of a macOS request is already snake case: the old encoder
    /// sent each one as the generated coder will, so no dictionary-valued or other field
    /// changes bytes. A migration's wire golden (030-043) must equal its old line exactly.
    @Test func noMacOSRequestKeyChangesBytes() throws {
        #expect(try Self.liveInventory().renamedKeys == [:])
    }

    /// The caller-authored keys (maps, JsonValue documents, objects with additional
    /// properties), named types included. Neither coder renames them; a migration checks
    /// that its hand-written type held a dictionary there and not a struct.
    @Test func listsTheDictionariesWhoseKeysGoAsGiven() throws {
        #expect(try Self.liveInventory().dictionaryFields == [
            "apps-dispatch.payload",
            "apps-mount.context",
            "apps-provider-result.body",
            "apps-run.args",
            "chief-inspect.query",
            "cloud-attachment-upload.poster",
            "cloud-attachment-upload.preview",
            "cloud-conversation-op.op",
            "cloud-inbox-op.op",
            "conversation-attachment-upload.poster",
            "conversation-attachment-upload.preview",
            "conversation-create.participants",
            "conversation-import.messages.parts",
            "conversation-import.messages.parts.preview",
            "conversation-inbox-op.op",
            "conversation-op.op",
            "create-browser-profile.source",
            "create-profile.defaults",
            "create-terminal.env",
            "import-session-organization.groups",
            "import-session-organization.workspaces",
            "move-tab-to-column.respawn.env",
            "move-tab-to-split.respawn.env",
            "new-pane-right.env",
            "new-pane.env",
            "new-row.env",
            "new-screen.env",
            "new-tab.env",
            "put-frontend-projection.projection",
            "put-session.capabilities",
            "put-session.transport",
            "set-default-colors.palette",
            "set-frontend-browser-history.history",
            "split.env",
            "update-browser-profile.proxy",
            "update-profile.defaults",
        ])
    }

    private static let fixture = #"""
    {
      "families": {},
      "types": {
        "JsonValue": {"kind": "opaque_json", "reason": "a document"},
        "TabRef": {"kind": "opaque_json", "reason": "a number or a string"},
        "Env": {"kind": "alias", "target": {"kind": "map", "values": {"kind": "scalar", "name": "string"}}},
        "Respawn": {"kind": "object", "additional_properties": false, "fields": {
          "env": {"type": {"kind": "ref", "name": "Env"}, "presence": "optional", "nullable": true},
          "mimeType": {"type": {"kind": "scalar", "name": "string"}, "presence": "optional", "nullable": true}
        }},
        "Node": {"kind": "tagged_union", "tag": "type", "variants": {
          "leaf": {"kind": "object", "additional_properties": true, "fields": {
            "type": {"type": {"kind": "literal", "value": "leaf"}, "presence": "required", "nullable": false}}},
          "split": {"kind": "object", "additional_properties": false, "fields": {
            "children": {"type": {"kind": "array", "items": {"kind": "ref", "name": "Node"}},
                         "presence": "required", "nullable": false},
            "meta": {"type": {"kind": "ref", "name": "JsonValue"}, "presence": "optional", "nullable": true}}}
        }}
      },
      "commands": {
        "move": {
          "clients": ["macos"],
          "request": {"kind": "object", "additional_properties": false, "fields": {
            "respawn": {"type": {"kind": "ref", "name": "Respawn"}, "presence": "optional", "nullable": true},
            "target": {"type": {"kind": "ref", "name": "TabRef"}, "presence": "optional", "nullable": false},
            "layout": {"type": {"kind": "ref", "name": "Node"}, "presence": "optional", "nullable": true},
            "inline": {"type": {"kind": "object", "additional_properties": false, "fields": {
              "byKind": {"type": {"kind": "map", "values": {"kind": "ref", "name": "Respawn"}},
                         "presence": "required", "nullable": false}}},
                       "presence": "optional", "nullable": true}
          }},
          "result": {"kind": "object", "fields": {}, "additional_properties": false}
        },
        "cli-only": {
          "clients": ["cli"],
          "request": {"kind": "object", "additional_properties": false, "fields": {
            "env": {"type": {"kind": "ref", "name": "Env"}, "presence": "optional", "nullable": true}}},
          "result": {"kind": "object", "fields": {}, "additional_properties": false}
        }
      }
    }
    """#

    /// A map or document behind a ref, an alias, a union or a map's values is listed under its
    /// path; a recursive type stops on its path; an opaque number-or-string is not a dictionary.
    @Test func walksNamedTypesAsInlineOnes() throws {
        let inventory = try RequestSchema(document: json(Self.fixture)).inventory
        #expect(inventory.dictionaryFields == [
            "move.inline.byKind",
            "move.inline.byKind.env",
            "move.layout",
            "move.layout.meta",
            "move.respawn.env",
        ])
        #expect(inventory.renamedKeys == [
            "move.inline.byKind": "by_kind",
            "move.inline.byKind.mimeType": "mime_type",
            "move.respawn.mimeType": "mime_type",
        ])
    }

    @Test func snakeCaseIsFoundations() {
        #expect(WireKeyInventory.snakeCase("mimeType") == "mime_type")
        #expect(WireKeyInventory.snakeCase("myURLProperty") == "my_url_property")
        #expect(WireKeyInventory.snakeCase("aURL") == "a_url")
        #expect(WireKeyInventory.snakeCase("HTTPServer") == "h_ttp_server")
        #expect(WireKeyInventory.snakeCase("terminal_id") == "terminal_id")
        #expect(WireKeyInventory.snakeCase("") == "")
    }
}
