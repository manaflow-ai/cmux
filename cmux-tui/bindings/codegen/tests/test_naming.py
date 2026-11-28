from __future__ import annotations

import unittest

from codegen.naming import (
    camel_case,
    find_collisions,
    pascal_case,
    safe_identifier,
    screaming_snake_case,
    snake_case,
    words,
)


class NamingTests(unittest.TestCase):
    def test_splits_wire_names_and_acronyms(self) -> None:
        self.assertEqual(words("HTTPServer-id"), ("http", "server", "id"))
        self.assertEqual(snake_case("workspace-created"), "workspace_created")
        self.assertEqual(pascal_case("workspace-created"), "WorkspaceCreated")
        self.assertEqual(camel_case("workspace-created"), "workspaceCreated")
        self.assertEqual(
            screaming_snake_case("workspace-created"), "WORKSPACE_CREATED"
        )

    def test_safe_identifier_handles_keywords_and_digits(self) -> None:
        self.assertEqual(
            safe_identifier("class", reserved={"class"}), "class_"
        )
        self.assertEqual(safe_identifier("42-answer"), "_42_answer")
        self.assertEqual(safe_identifier("---"), "_")

    def test_collision_reporting_is_sorted(self) -> None:
        self.assertEqual(
            find_collisions(["foo-bar", "foo_bar"], style="snake"),
            {"foo_bar": ("foo-bar", "foo_bar")},
        )

    def test_rejects_unknown_style(self) -> None:
        with self.assertRaisesRegex(ValueError, "unknown identifier style"):
            safe_identifier("value", style="kebab")


if __name__ == "__main__":
    unittest.main()
