from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def schema_document() -> dict[str, Any]:
    empty_object = {
        "kind": "object",
        "fields": {},
        "additional_properties": False,
    }
    return {
        "$schema": "./sdk-schema.schema.json",
        "schema_version": 2,
        "protocol": {
            "name": "cmux-tui-mux",
            "version": 10,
            "id_type": "uint64",
            "javascript_id_policy": "Decode identifiers losslessly.",
        },
        "profiles": {
            "control": {
                "description": "Ordinary control clients.",
                "inherits": [],
            }
        },
        "types": {
            "EmptyResult": empty_object,
            "Id": {
                "kind": "alias",
                "target": {"kind": "scalar", "name": "uint64"},
            },
            "Workspace": {
                "kind": "object",
                "fields": {
                    "id": {
                        "type": {"kind": "ref", "name": "Id"},
                        "presence": "required",
                        "nullable": False,
                    }
                },
                "additional_properties": False,
            },
        },
        "commands": {
            "list-workspaces": {
                "authority": "control",
                "since": 1,
                "capability": None,
                "request": empty_object,
                "result": {
                    "kind": "array",
                    "items": {"kind": "ref", "name": "Workspace"},
                },
                "stream": None,
                "constraints": [],
            }
        },
        "events": {
            "workspace-created": {
                "since": 1,
                "capability": None,
                "streams": ["subscribe"],
                "emission": "emitted",
                "payload": {
                    "kind": "object",
                    "fields": {
                        "workspace": {
                            "type": {"kind": "ref", "name": "Workspace"},
                            "presence": "required",
                            "nullable": False,
                        }
                    },
                    "additional_properties": False,
                },
            }
        },
    }


def write_schema(directory: Path, document: dict[str, Any] | None = None) -> Path:
    path = directory / "sdk-schema.json"
    path.write_text(
        json.dumps(document if document is not None else schema_document(), indent=2)
        + "\n",
        encoding="utf-8",
    )
    return path
