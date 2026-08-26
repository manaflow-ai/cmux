from __future__ import annotations

import unittest

from codegen.validate import ValidationError, validate_document

from support import schema_document


class ValidateTests(unittest.TestCase):
    def test_accepts_valid_document(self) -> None:
        validate_document(schema_document())

    def test_rejects_unknown_type_construct(self) -> None:
        document = schema_document()
        document["types"]["Id"] = {"kind": "magic"}
        with self.assertRaisesRegex(ValidationError, "unknown type construct"):
            validate_document(document)

    def test_rejects_unknown_scalar(self) -> None:
        document = schema_document()
        document["types"]["Id"]["target"]["name"] = "usize"
        with self.assertRaisesRegex(ValidationError, "must be one of"):
            validate_document(document)

    def test_rejects_unresolved_reference(self) -> None:
        document = schema_document()
        document["types"]["Workspace"]["fields"]["id"]["type"]["name"] = "Missing"
        with self.assertRaisesRegex(ValidationError, "unknown type 'Missing'"):
            validate_document(document)

    def test_rejects_profile_cycle(self) -> None:
        document = schema_document()
        document["profiles"]["control"]["inherits"] = ["admin"]
        document["profiles"]["admin"] = {
            "description": "Administrator.",
            "inherits": ["control"],
        }
        with self.assertRaisesRegex(ValidationError, "inheritance cycle"):
            validate_document(document)

    def test_rejects_derived_api_name_collision(self) -> None:
        document = schema_document()
        document["commands"]["list_workspaces"] = dict(
            document["commands"]["list-workspaces"]
        )
        with self.assertRaisesRegex(ValidationError, "API name 'list_workspaces'"):
            validate_document(document)

    def test_rejects_stream_reference_to_unknown_event(self) -> None:
        document = schema_document()
        document["commands"]["list-workspaces"]["stream"] = {
            "kind": "events",
            "event_names": ["missing-event"],
            "ordering": "per connection",
            "terminal_event": None,
        }
        with self.assertRaisesRegex(ValidationError, "unknown event 'missing-event'"):
            validate_document(document)

    def test_rejects_non_object_request_and_payload(self) -> None:
        document = schema_document()
        document["commands"]["list-workspaces"]["request"] = {
            "kind": "ref",
            "name": "EmptyResult",
        }
        document["events"]["workspace-created"]["payload"] = {
            "kind": "ref",
            "name": "Workspace",
        }
        with self.assertRaises(ValidationError) as raised:
            validate_document(document)
        message = str(raised.exception)
        self.assertIn("command request must be an object", message)
        self.assertIn("event payload must be an object", message)

    def test_rejects_invalid_stream_and_emission_values(self) -> None:
        document = schema_document()
        document["events"]["workspace-created"]["streams"] = ["other"]
        document["events"]["workspace-created"]["emission"] = "sometimes"
        document["commands"]["list-workspaces"]["stream"] = {
            "kind": "other",
            "event_names": ["workspace-created"],
            "ordering": "per connection",
            "terminal_event": None,
        }
        with self.assertRaises(ValidationError) as raised:
            validate_document(document)
        message = str(raised.exception)
        self.assertIn("$.commands.list-workspaces.stream.kind", message)
        self.assertIn("$.events.workspace-created.emission", message)
        self.assertIn("$.events.workspace-created.streams[0]", message)

    def test_rejects_duplicate_array_values(self) -> None:
        document = schema_document()
        document["events"]["workspace-created"]["streams"] = [
            "subscribe",
            "subscribe",
        ]
        with self.assertRaisesRegex(ValidationError, "must contain unique values"):
            validate_document(document)

    def test_rejects_missing_and_unknown_keys_in_rich_schema(self) -> None:
        document = schema_document()
        del document["commands"]["list-workspaces"]["constraints"]
        document["events"]["workspace-created"]["surprise"] = True
        with self.assertRaises(ValidationError) as raised:
            validate_document(document)
        message = str(raised.exception)
        self.assertIn("missing required key 'constraints'", message)
        self.assertIn("$.events.workspace-created.surprise: unknown key", message)

    def test_rich_schema_requires_command_and_event_objects(self) -> None:
        document = schema_document()
        document["commands"] = list(document["commands"].values())
        document["events"] = list(document["events"].values())
        with self.assertRaises(ValidationError) as raised:
            validate_document(document)
        message = str(raised.exception)
        self.assertIn("$.commands: must be an object", message)
        self.assertIn("$.events: must be an object", message)


if __name__ == "__main__":
    unittest.main()
