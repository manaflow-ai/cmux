from __future__ import annotations

import unittest
import inspect
from typing import Any, Mapping

from cmux.raw._generated import codec
from cmux.raw._generated._schema import SCHEMA
from cmux.raw._generated.codec import (
    decode_command_result,
    decode_event,
    encode_request,
)
from cmux.raw._generated.client import GeneratedClientMixin


class _RecordingClient(GeneratedClientMixin):
    def _invoke_command(self, _command, request):
        return request

    def _open_command_stream(self, _command, request):
        return request


def _numeric_sample(constraints: Any, *, floating: bool) -> Any:
    minimum = 0.0 if floating else 0
    maximum = None
    for constraint in constraints or ():
        if not isinstance(constraint, Mapping):
            continue
        if "minimum" in constraint:
            minimum = constraint["minimum"]
        if "maximum" in constraint:
            maximum = constraint["maximum"]
    if maximum is not None:
        value = (minimum + maximum) / 2
    else:
        value = max(minimum, 1)
    return float(value) if floating else int(value)


def _sample(
    expression: Mapping[str, Any],
    *,
    constraints: Any = (),
) -> Any:
    kind = expression["kind"]
    if kind == "scalar":
        name = expression["name"]
        if name == "string":
            minimum = 1
            for constraint in constraints or ():
                if isinstance(constraint, Mapping):
                    minimum = max(minimum, int(constraint.get("min_length", 0)))
            return "x" * minimum
        if name == "boolean":
            return True
        return _numeric_sample(constraints, floating=name.startswith("float"))
    if kind == "literal":
        return expression["value"]
    if kind == "enum":
        return expression["values"][0]
    if kind == "ref":
        return _sample(SCHEMA["types"][expression["name"]], constraints=constraints)
    if kind == "alias":
        return _sample(expression["target"], constraints=constraints)
    if kind == "array":
        count = max(0, int(expression.get("min_items", 0)))
        return [_sample(expression["items"]) for _ in range(count)]
    if kind == "map":
        return {}
    if kind == "opaque_json":
        return {"opaque": True}
    if kind == "tagged_union":
        _variant, variant_type = next(iter(expression["variants"].items()))
        return _sample(variant_type)
    if kind == "untagged_union":
        return _sample(expression["variants"][0])
    if kind == "object":
        return {
            name: _sample(field["type"], constraints=field.get("constraints", ()))
            for name, field in expression["fields"].items()
            if field["presence"] == "required"
        }
    raise AssertionError(f"unsupported schema expression {kind}")


class SchemaRoundTripTests(unittest.TestCase):
    def test_every_command_request_encodes(self) -> None:
        for command, definition in SCHEMA["commands"].items():
            with self.subTest(command=command):
                path = f"commands/{command}/request"
                request_type = codec.MODEL_BY_PATH[path]
                required = {
                    codec.PYTHON_FIELD_NAMES.get(name, name.replace("-", "_")): _sample(
                        field["type"],
                        constraints=field.get("constraints", ()),
                    )
                    for name, field in definition["request"]["fields"].items()
                    if field["presence"] == "required"
                }
                encoded = encode_request(command, request_type(**required))
                self.assertEqual(
                    set(encoded),
                    {
                        name
                        for name, field in definition["request"]["fields"].items()
                        if field["presence"] == "required"
                    },
                )

    def test_every_generated_method_exposes_every_request_field(self) -> None:
        client = _RecordingClient()
        for command, definition in SCHEMA["commands"].items():
            with self.subTest(command=command):
                method = getattr(client, command.replace("-", "_"))
                signature = inspect.signature(method)
                expected_names = {
                    codec.PYTHON_FIELD_NAMES.get(name, name.replace("-", "_"))
                    for name in definition["request"]["fields"]
                }
                self.assertEqual(set(signature.parameters), expected_names)
                required = {
                    codec.PYTHON_FIELD_NAMES.get(name, name.replace("-", "_")): _sample(
                        field["type"],
                        constraints=field.get("constraints", ()),
                    )
                    for name, field in definition["request"]["fields"].items()
                    if field["presence"] == "required"
                }
                request = method(**required)
                self.assertEqual(
                    set(encode_request(command, request)),
                    {
                        name
                        for name, field in definition["request"]["fields"].items()
                        if field["presence"] == "required"
                    },
                )

    def test_every_command_result_decodes(self) -> None:
        for command, definition in SCHEMA["commands"].items():
            with self.subTest(command=command):
                decode_command_result(command, _sample(definition["result"]))

    def test_every_known_event_decodes(self) -> None:
        for event_name, definition in SCHEMA["events"].items():
            with self.subTest(event=event_name):
                event = decode_event(_sample(definition["payload"]))
                self.assertEqual(event.event, event_name)


if __name__ == "__main__":
    unittest.main()
