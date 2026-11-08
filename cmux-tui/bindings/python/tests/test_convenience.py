from __future__ import annotations

import unittest
from dataclasses import replace

import cmux.raw as cmux
from cmux.raw import (
    CmuxClient,
    LayoutLeaf,
    LivePane,
    ReadScrollbackResult,
    RenderRow,
    RenderRun,
    Screen,
    SurfaceContext,
    Tab,
    Tree,
    Workspace,
    active_live_pty,
    find_surface,
    render_row_text,
)


def tab(surface: int, *, kind: str = "pty", dead: bool = False) -> Tab:
    return Tab(
        surface=surface,
        browser_source="launched" if kind == "browser" else None,
        dead=dead,
        kind=kind,
        name=None,
        size=None,
        title=f"surface {surface}",
    )


def pane(identifier: int, tabs: list[Tab], active_tab: int = 0) -> LivePane:
    return LivePane(
        active_tab=active_tab,
        id=identifier,
        name=f"pane {identifier}",
        tabs=tabs,
    )


def screen(
    identifier: int,
    panes: list[LivePane],
    *,
    active: bool,
    active_pane: int,
) -> Screen:
    return Screen(
        active=active,
        active_pane=active_pane,
        id=identifier,
        layout=LayoutLeaf(pane=active_pane, type="leaf"),
        name=f"screen {identifier}",
        panes=panes,
        zoomed_pane=None,
    )


def topology() -> Tree:
    return Tree(
        workspaces=[
            Workspace(
                active=False,
                id=1,
                name="inactive",
                screens=[
                    screen(
                        2,
                        [pane(3, [tab(7)])],
                        active=True,
                        active_pane=3,
                    )
                ],
            ),
            Workspace(
                active=True,
                id=10,
                name="active",
                screens=[
                    screen(
                        20,
                        [
                            pane(30, [tab(41), tab(42)], active_tab=1),
                            pane(31, [tab(43)]),
                        ],
                        active=True,
                        active_pane=30,
                    )
                ],
            ),
        ]
    )


class TopologyTests(unittest.TestCase):
    def test_find_surface_returns_generated_model_context(self) -> None:
        tree = topology()

        context = find_surface(tree, 42)

        self.assertIsInstance(context, SurfaceContext)
        assert context is not None
        self.assertIs(context.workspace, tree.workspaces[1])
        self.assertIs(context.screen, tree.workspaces[1].screens[0])
        self.assertIs(context.pane, tree.workspaces[1].screens[0].panes[0])
        self.assertIs(context.tab, context.pane.tabs[1])
        self.assertIsNone(find_surface(tree, 999))

    def test_active_live_pty_is_strict_and_does_not_fall_back(self) -> None:
        tree = topology()
        context = active_live_pty(tree)
        assert context is not None
        self.assertEqual(context.tab.surface, 42)

        active_screen = tree.workspaces[1].screens[0]
        browser_pane = pane(30, [tab(44, kind="browser")])
        browser_tree = replace(
            tree,
            workspaces=[
                tree.workspaces[0],
                replace(
                    tree.workspaces[1],
                    screens=[
                        replace(
                            active_screen,
                            panes=[browser_pane, active_screen.panes[1]],
                        )
                    ],
                ),
            ],
        )
        self.assertIsNone(
            active_live_pty(browser_tree),
            "the inactive live PTY must not replace an active browser tab",
        )

        invalid_index = replace(
            tree,
            workspaces=[
                tree.workspaces[0],
                replace(
                    tree.workspaces[1],
                    screens=[
                        replace(
                            active_screen,
                            panes=[
                                replace(active_screen.panes[0], active_tab=99),
                                active_screen.panes[1],
                            ],
                        )
                    ],
                ),
            ],
        )
        self.assertIsNone(active_live_pty(invalid_index))


class RenderAndScrollbackTests(unittest.TestCase):
    def test_render_row_text_removes_styles_but_preserves_text(self) -> None:
        row = RenderRow(
            row=4,
            runs=[
                RenderRun(attrs=1, bg=None, fg="#ffffff", text="hello"),
                RenderRun(attrs=2, bg="#000000", fg=None, text="  world "),
            ],
        )

        self.assertEqual(render_row_text(row), "hello  world ")

    def test_read_scrollback_tail_probes_then_reads_tail(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        calls = []
        tail = ReadScrollbackResult(epoch=1, rows=[], start=7, total=10)
        responses = [
            ReadScrollbackResult(epoch=1, rows=[], start=0, total=10),
            tail,
        ]

        def read_scrollback(surface, start, count):
            calls.append((surface, start, count))
            return responses.pop(0)

        client.read_scrollback = read_scrollback

        self.assertIs(client.read_scrollback_tail(9, 3), tail)
        self.assertEqual(calls, [(9, 0, 3), (9, 7, 3)])

    def test_read_scrollback_tail_reuses_probe_when_it_contains_tail(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        calls = []
        probe = ReadScrollbackResult(epoch=1, rows=[], start=0, total=2)

        def read_scrollback(surface, start, count):
            calls.append((surface, start, count))
            return probe

        client.read_scrollback = read_scrollback

        self.assertIs(client.read_scrollback_tail(9, 3), probe)
        self.assertEqual(calls, [(9, 0, 3)])

    def test_read_scrollback_tail_validates_count_before_io(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client.read_scrollback = lambda *_args, **_kwargs: self.fail("unexpected I/O")

        for count in (-1, 65_536):
            with self.subTest(count=count), self.assertRaises(ValueError):
                client.read_scrollback_tail(9, count)
        for count in (True, 1.5, "3"):
            with self.subTest(count=count), self.assertRaises(TypeError):
                client.read_scrollback_tail(9, count)


class PublicApiTests(unittest.TestCase):
    def test_installed_package_exports_convenience_api(self) -> None:
        expected = {
            "SurfaceContext": SurfaceContext,
            "active_live_pty": active_live_pty,
            "find_surface": find_surface,
            "render_row_text": render_row_text,
        }
        for name, value in expected.items():
            with self.subTest(name=name):
                self.assertIn(name, cmux.__all__)
                self.assertIs(getattr(cmux, name), value)
        self.assertTrue(hasattr(CmuxClient, "read_scrollback_tail"))


if __name__ == "__main__":
    unittest.main()
