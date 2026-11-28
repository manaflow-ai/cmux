"""The Swift FFI emitter: app wire types generated from the Rust rule crates' serde types (codegen/swift_ffi)."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from codegen.swift_ffi import generate
from codegen.swift_ffi.emit import HEADER_MARK, BindingError, Emitter
from codegen.swift_ffi.rust_types import read_crate

CODEGEN = Path(__file__).resolve().parents[1]
REPO = CODEGEN.parents[2]

RUST = '''
/// What a close reads.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Facts {
    /// The tab's kind, with a comma, in its doc.
    pub tab_kind: String,
    pub url: Option<String>,
    #[serde(rename = "ids")]
    pub tab_ids: Vec<u64>,
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Warning {
    Agent { name: Option<String> },
    Programs { programs: Vec<String>, unanswered: Vec<String> },
    Quiet,
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum Fit {
    Fill,
    NativeSize,
    #[serde(other)]
    Unknown,
}

#[derive(Serialize)]
pub struct Wrapped(pub u64);

#[derive(Serialize)]
pub struct Flat {
    #[serde(flatten)]
    pub inner: Facts,
}

#[cfg(test)]
mod tests {
    pub struct NotRead { pub a: u8 }
}
'''


def crate(tmp: Path) -> dict:
    src = tmp / "src"
    src.mkdir()
    (src / "close.rs").write_text(RUST, encoding="utf-8")
    return read_crate(src)


class RustReaderTests(unittest.TestCase):
    def test_reads_structs_enums_docs_and_serde_attributes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            items = crate(Path(tmp))
        self.assertNotIn("close::NotRead", items)
        facts = items["close::Facts"]
        self.assertEqual([f.name for f in facts.fields], ["tab_kind", "url", "tab_ids"])
        self.assertEqual(facts.fields[0].attrs.docs, ["The tab's kind, with a comma, in its doc."])
        self.assertEqual(facts.attrs.serde, {"rename_all": "camelCase", "default": True})
        self.assertEqual(facts.fields[2].attrs.serde["rename"], "ids")
        warning = items["close::Warning"]
        self.assertEqual([(v.name, v.kind) for v in warning.variants], [("Agent", "struct"), ("Programs", "struct"), ("Quiet", "unit")])


class EmitterTests(unittest.TestCase):
    def render(self, types: dict, **extra) -> str:
        with tempfile.TemporaryDirectory() as tmp:
            items = crate(Path(tmp))
        return Emitter(items, {"types": types, **extra}).render(list(types))

    def test_a_struct_keeps_rust_wire_names_and_optionality(self) -> None:
        out = self.render({"close::Facts": {"swift": "Rules.Facts", "init": True}})
        self.assertTrue(out.startswith(HEADER_MARK + "\n"))
        self.assertIn("extension Rules {", out)
        self.assertIn("public nonisolated struct Facts: Codable, Equatable, Sendable {", out)
        self.assertIn("public var tabKind: String", out)
        self.assertIn("public var url: String?", out)
        self.assertIn("public var tabIds: [UInt64]", out)
        self.assertIn('tabIds = "ids"', out)
        self.assertIn("/// The tab's kind, with a comma, in its doc.", out)

    def test_hand_overrides_rename_and_retype_fields(self) -> None:
        out = self.render({"close::Facts": {
            "swift": "Rules.Facts", "init": "kind, url = nil",
            "fields": {"tab_kind": {"swift": "kind"}}, "omit": ["tab_ids"],
        }})
        self.assertIn("public var kind: String", out)
        self.assertIn('kind = "tabKind"', out)
        self.assertNotIn("tabIds", out)
        self.assertIn("public init(kind: String, url: String? = nil)", out)

    def test_an_init_spec_must_name_every_property(self) -> None:
        with self.assertRaises(BindingError):
            self.render({"close::Facts": {"swift": "Rules.Facts", "init": "tabKind"}})

    def test_an_internally_tagged_enum_decodes_its_tag(self) -> None:
        out = self.render({"close::Warning": {"swift": "Rules.Warning", "conforms": ["Decodable", "Equatable", "Sendable"]}})
        self.assertIn("case agent(name: String?)", out)
        self.assertIn('switch try container.decode(String.self, forKey: .kind)', out)
        self.assertIn('case "quiet": self = .quiet', out)
        self.assertIn("dataCorruptedError", out)

    def test_a_string_enum_with_other_falls_back(self) -> None:
        out = self.render({"close::Fit": {"swift": "Rules.Fit"}})
        self.assertIn('case nativeSize', out)
        self.assertIn(".unknown", out)

    def test_shapes_the_emitter_cannot_express_fail_closed(self) -> None:
        for key in ("close::Wrapped", "close::Flat"):
            with self.subTest(key), self.assertRaises(BindingError):
                self.render({key: {"swift": f"Rules.{key.split('::')[1]}"}})


class GenerateTests(unittest.TestCase):
    def test_every_bindings_file_generates_and_none_is_still_hand_written(self) -> None:
        self.assertEqual(generate.main(["--check"]), 0)

    def test_out_refuses_a_sources_folder(self) -> None:
        with self.assertRaises(BindingError):
            generate.check_out_folder(REPO / "Packages/macOS/CmuxNext/Sources/CmuxNextWindowRules", REPO)

    def test_write_refuses_to_replace_a_hand_written_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "X.generated.swift").write_text("struct Hand {}\n", encoding="utf-8")
            with self.assertRaises(BindingError):
                generate.write("X.generated.swift", HEADER_MARK + "\n", Path(tmp))

    def test_hand_written_declarations_nest_by_extension(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "A.swift").write_text(
                "extension Rules {\n    // struct Commented {}\n    public struct Facts {\n        enum Inner {}\n"
                "        func f() { struct Local {} }\n    }\n}\n", encoding="utf-8")
            found = generate.hand_written_declarations(Path(tmp))
        self.assertEqual(sorted(found), ["Rules.Facts", "Rules.Facts.Inner"])


if __name__ == "__main__":
    unittest.main()
