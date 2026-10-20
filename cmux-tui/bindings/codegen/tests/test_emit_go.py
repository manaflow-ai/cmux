from __future__ import annotations

import unittest

from codegen.emit_go import emit
from codegen.ir import load_ir_document

from support import schema_document


class GoEmitterTests(unittest.TestCase):
    def test_nullable_fields_use_exact_generated_presence_types(self) -> None:
        document = schema_document()
        document["types"]["Mode"] = {
            "kind": "enum",
            "values": ["running", "stopped"],
        }
        document["types"]["Workspace"]["fields"].update(
            {
                "name": {
                    "type": {"kind": "scalar", "name": "string"},
                    "presence": "optional",
                    "nullable": True,
                },
                "mode": {
                    "type": {"kind": "ref", "name": "Mode"},
                    "presence": "required",
                    "nullable": True,
                },
                "source": {
                    "type": {
                        "kind": "enum",
                        "values": ["external", "launched"],
                    },
                    "presence": "optional",
                    "nullable": True,
                },
                "lifecycle": {
                    "type": {"kind": "literal", "value": "running"},
                    "presence": "required",
                    "nullable": True,
                },
                "label": {
                    "type": {"kind": "scalar", "name": "string"},
                    "presence": "optional",
                    "nullable": False,
                },
            }
        )

        generated = emit(load_ir_document(document))
        types = generated["generated_types.go"]
        presence_tests = generated["generated_presence_test.go"]

        self.assertRegex(types, r"Name\s+Presence\[string\]")
        self.assertRegex(types, r"Mode\s+RequiredNullable\[Mode\]")
        self.assertRegex(types, r"Source\s+Presence\[WorkspaceSource\]")
        self.assertRegex(
            types,
            r"Lifecycle\s+RequiredNullable\[WorkspaceLifecycle\]",
        )
        self.assertIn(
            'WorkspaceLifecycleRunning WorkspaceLifecycle = "running"',
            types,
        )
        self.assertRegex(types, r"Label\s+\*string")
        self.assertIn("required field mode is missing", types)
        self.assertRegex(types, r"Label\s+optionalNonNullJSON\[string\]")
        self.assertIn("if fields.Label.null", types)
        for field in ("Name", "Mode", "Source", "Lifecycle", "Label"):
            self.assertIn(f't.Run("Workspace.{field}"', presence_tests)
        self.assertRegex(
            presence_tests,
            r"generatedFieldShapeCount\s+= 5",
        )
        self.assertRegex(
            presence_tests,
            r"generatedOptionalNullableFieldCount\s+= 2",
        )
        self.assertRegex(
            presence_tests,
            r"generatedRequiredNullableFieldCount\s+= 2",
        )
        self.assertRegex(
            presence_tests,
            r"generatedOptionalNonnullableFieldCount\s+= 1",
        )

    def test_decoders_reject_missing_required_and_invalid_constraints(self) -> None:
        document = schema_document()
        document["types"]["Mode"] = {
            "kind": "enum",
            "values": ["running", "stopped"],
        }
        document["types"]["Workspace"]["fields"].update(
            {
                "mode": {
                    "type": {"kind": "ref", "name": "Mode"},
                    "presence": "required",
                    "nullable": False,
                },
                "source": {
                    "type": {
                        "kind": "enum",
                        "values": ["external", "launched"],
                    },
                    "presence": "required",
                    "nullable": False,
                },
                "lifecycle": {
                    "type": {"kind": "literal", "value": "running"},
                    "presence": "required",
                    "nullable": False,
                },
            }
        )

        generated = emit(load_ir_document(document))
        types = generated["generated_types.go"]
        presence_tests = generated["generated_presence_test.go"]

        self.assertIn("func (value *Mode) UnmarshalJSON", types)
        self.assertIn("required field id is missing", types)
        self.assertIn("required field lifecycle is missing", types)
        self.assertRegex(types, r"Source\s+WorkspaceSource")
        self.assertRegex(types, r"Lifecycle\s+WorkspaceLifecycle")
        self.assertIn(
            "func (value WorkspaceSource) MarshalJSON",
            types,
        )
        self.assertIn("switch decoded.Source", types)
        self.assertIn("switch decoded.Lifecycle", types)
        self.assertIn(
            "func TestGeneratedRequiredFieldsRejectOmission",
            presence_tests,
        )
        self.assertIn(
            "func TestGeneratedRequiredNonnullableFieldsRejectNull",
            presence_tests,
        )
        self.assertIn(
            "func TestGeneratedConstrainedFieldsRejectUnknownValues",
            presence_tests,
        )
        self.assertIn(
            "func TestGeneratedConstrainedFieldsRejectUnknownValuesOnMarshal",
            presence_tests,
        )
        for field in ("ID", "Mode", "Source", "Lifecycle"):
            self.assertIn(f't.Run("Workspace.{field}"', presence_tests)
        self.assertRegex(
            presence_tests,
            r"generatedRequiredFieldCount\s+= 5",
        )
        self.assertRegex(
            presence_tests,
            r"generatedConstrainedFieldCount\s+= 3",
        )

    def test_command_maps_propagate_presence_encoding_errors(self) -> None:
        document = schema_document()
        document["commands"]["list-workspaces"]["request"]["fields"] = {
            "filter": {
                "type": {"kind": "scalar", "name": "string"},
                "presence": "optional",
                "nullable": True,
            }
        }

        generated = emit(load_ir_document(document))
        commands = generated["generated_commands.go"]

        self.assertIn("Filter Presence[string]", commands)
        self.assertIn("params, err := commandMap(options)", commands)
        self.assertIn(
            "ErrInvalidArgument, err)",
            commands,
        )

    def test_shaped_methods_reject_invalid_inline_constraints(self) -> None:
        document = schema_document()
        document["commands"]["list-workspaces"]["request"]["fields"] = {
            "mode": {
                "type": {
                    "kind": "enum",
                    "values": ["active", "all"],
                },
                "presence": "required",
                "nullable": False,
            }
        }

        generated = emit(load_ir_document(document))
        commands = generated["generated_commands.go"]

        self.assertIn("type ListWorkspacesRequestMode string", commands)
        self.assertIn(
            "mode ListWorkspacesRequestMode",
            commands,
        )
        self.assertIn("switch mode", commands)
        self.assertIn(
            "encode list-workspaces.mode: invalid value",
            commands,
        )
        self.assertIn("ErrInvalidArgument", commands)

    def test_additional_properties_survive_custom_presence_json(self) -> None:
        document = schema_document()
        document["types"]["Extensible"] = {
            "kind": "object",
            "fields": {
                "name": {
                    "type": {"kind": "scalar", "name": "string"},
                    "presence": "optional",
                    "nullable": True,
                }
            },
            "additional_properties": True,
        }

        generated = emit(load_ir_document(document))
        types = generated["generated_types.go"]

        self.assertIn(
            "for key, fieldValue := range value.Additional",
            types,
        )
        self.assertIn(
            "decoded.Additional = make(map[string]json.RawMessage)",
            types,
        )
        self.assertIn(
            "json.RawMessage(nil), fieldValue...",
            types,
        )
        self.assertIn(
            'case "name":',
            types,
        )

    def test_command_metadata_includes_field_compatibility_maps(self) -> None:
        document = schema_document()
        request = document["commands"]["list-workspaces"]["request"]
        request["fields"] = {
            "future": {
                "type": {"kind": "scalar", "name": "string"},
                "presence": "optional",
                "nullable": False,
                "since": 7,
            },
            "filtered": {
                "type": {"kind": "scalar", "name": "uint64"},
                "presence": "optional",
                "nullable": False,
                "capability": "filtered-workspaces",
            },
        }

        generated = emit(load_ir_document(document))
        metadata = generated["generated_metadata.go"]

        self.assertRegex(metadata, r"FieldSince\s+map\[string\]uint32")
        self.assertRegex(metadata, r"FieldCapabilities\s+map\[string\]string")
        self.assertIn(
            'FieldSince: map[string]uint32{"future": 7}',
            metadata,
        )
        self.assertIn(
            'FieldCapabilities: map[string]string{"filtered": "filtered-workspaces"}',
            metadata,
        )
        self.assertIn("cloneCommandMetadata(commandMetadata", metadata)

    def test_commands_without_field_gates_emit_nil_maps(self) -> None:
        generated = emit(load_ir_document(schema_document()))
        metadata = generated["generated_metadata.go"]

        self.assertIn("FieldSince: nil, FieldCapabilities: nil", metadata)


if __name__ == "__main__":
    unittest.main()
