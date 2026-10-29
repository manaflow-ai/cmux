from __future__ import annotations

import pathlib
import unittest

from cmux import Client, MachineId, SessionId, WorkspaceId

from fake_cmux_server import (
    MACHINE_B,
    SESSION_A,
    SESSION_B,
    FakeCmuxServer,
)
from orchestrator import (
    Job,
    OrchestratorConfig,
    OrchestrationError,
    SelectionError,
    creation_key,
    default_jobs,
    load_jobs,
    mutation_key,
    orchestrate,
    select_session,
    select_workspace,
)


class PythonDevOrchestratorTests(unittest.TestCase):
    def test_fake_server_emits_canonical_terminal_snapshot(self) -> None:
        with FakeCmuxServer() as server:
            workspace_id = server.seed_workspace("canonical")
            screen_id = "screen_" + "1" * 32
            pane_id = "pane_" + "2" * 32
            tab_id = "tab_" + "3" * 32
            terminal_id = "term_" + "4" * 32
            server.screens[screen_id] = {
                "id": screen_id,
                "workspace_id": workspace_id,
                "name": None,
                "index": 0,
                "focused": True,
                "layout": {
                    "kind": "leaf",
                    "pane_id": pane_id,
                    "tab_ids": [tab_id],
                    "active_tab_id": tab_id,
                },
            }
            server.panes[pane_id] = {
                "id": pane_id,
                "screen_id": screen_id,
                "name": None,
                "focused": True,
                "zoomed": False,
            }
            server._add_terminal(tab_id, terminal_id, pane_id, None, None)

            snapshot = server._full_snapshot(SESSION_A)

        self.assertEqual(snapshot["terminals"][0]["tab_ids"], [tab_id])
        self.assertNotIn("tab_id", snapshot["terminals"][0])

    def test_duplicate_session_names_require_a_typed_id(self) -> None:
        with FakeCmuxServer(duplicate_session_name=True) as server:
            with Client(server.path, timeout=1.0) as client:
                with self.assertRaisesRegex(
                    SelectionError,
                    "pass --session-id",
                ):
                    select_session(client, session_name="main")

                machine, session = select_session(
                    client,
                    session_name="ignored-when-id-is-present",
                    machine_id=MachineId(MACHINE_B),
                    session_id=SessionId(SESSION_B),
                )

        self.assertEqual(machine.id, MachineId(MACHINE_B))
        self.assertEqual(session.id, SessionId(SESSION_B))
        self.assertEqual(server.errors, [])

    def test_duplicate_workspace_names_require_a_typed_id(self) -> None:
        with FakeCmuxServer() as server:
            first = server.seed_workspace("duplicate")
            second = server.seed_workspace("duplicate")
            with Client(server.path, timeout=1.0) as client:
                _machine, session = select_session(client, session_name="main")
                with self.assertRaisesRegex(
                    SelectionError,
                    "pass --workspace-id",
                ):
                    select_workspace(
                        session,
                        workspace_name="duplicate",
                    )
                selected = select_workspace(
                    session,
                    workspace_name="ignored-when-id-is-present",
                    workspace_id=WorkspaceId(second),
                )

        self.assertNotEqual(first, second)
        self.assertIsNotNone(selected)
        assert selected is not None
        self.assertEqual(selected.id, WorkspaceId(second))
        self.assertEqual(server.errors, [])

    def test_full_pipeline_uses_exact_commands_events_revisions_and_cleanup(
        self,
    ) -> None:
        with FakeCmuxServer(
            replayed_operations=("tab.create_terminal",),
        ) as server:
            with Client(server.path, timeout=1.0) as client:
                result = orchestrate(
                    client,
                    OrchestratorConfig(
                        run_id="pipeline-42",
                        request_timeout=1.0,
                        event_ready_timeout=1.0,
                        terminal_wait_timeout_ms=100,
                        cwd="/work/project",
                    ),
                )

            requests = list(server.requests)
            remaining = server.workspace_ids("python-ci-pipeline-42")

        self.assertTrue(result.cleaned_up)
        self.assertEqual(remaining, [])
        self.assertEqual(
            [job.name for job in result.jobs],
            ["setup", "build", "tests"],
        )
        self.assertEqual(
            [job.output.strip().splitlines()[-1] for job in result.jobs],
            ["CMUX_SETUP_READY", "CMUX_BUILD_OK", "CMUX_TESTS_OK"],
        )
        self.assertEqual([job.exit_code for job in result.jobs], [0, 0, 0])
        self.assertEqual(result.event_kinds[0], "snapshot")
        self.assertGreaterEqual(result.event_kinds.count("delta"), 7)
        self.assertIn("tab.create_terminal", result.replayed_actions)

        create = next(
            request
            for request in requests
            if request["operation"] == "workspace.create"
        )
        self.assertEqual(create["params"]["initial_content"], "empty")
        self.assertNotIn("expected_revision", create["params"])

        mutations = [
            request
            for request in requests
            if request["operation"]
            in {
                "screen.create",
                "pane.split",
                "tab.create_terminal",
                "pane.run",
                "workspace.close",
            }
        ]
        self.assertEqual(
            [request["params"]["expected_revision"] for request in mutations],
            ["1", "2", "3", "4", "6", "8", "10"],
        )
        self.assertEqual(
            len({request["idempotency_key"] for request in mutations}),
            len(mutations),
        )

        runs = [
            request for request in requests if request["operation"] == "pane.run"
        ]
        self.assertEqual(
            [request["params"]["argv"][-1] for request in runs],
            [
                "print('CMUX_SETUP_READY')",
                "print('CMUX_BUILD_OK')",
                "print('CMUX_TESTS_OK')",
            ],
        )
        self.assertTrue(
            all(request["params"]["cwd"] == "/work/project" for request in runs)
        )
        creates = [
            request
            for request in requests
            if request["operation"]
            in {
                "workspace.create",
                "screen.create",
                "pane.split",
                "tab.create_terminal",
                "pane.run",
            }
        ]
        self.assertTrue(
            all(
                isinstance(request["params"].get("correlation_key"), str)
                for request in creates
            )
        )
        self.assertTrue(
            all(
                request["params"]["correlation_key"]
                != request["idempotency_key"]
                for request in creates
            )
        )
        self.assertEqual(
            len({request["params"]["correlation_key"] for request in creates}),
            len(creates),
        )
        self.assertIn("session.events", server.operations())
        self.assertEqual(server.operations().count("terminal.wait_exit"), 3)
        self.assertIn("stream.cancel", server.operations())
        self.assertEqual(server.errors, [])

    def test_applied_indeterminate_workspace_create_reconciles_without_retry(
        self,
    ) -> None:
        with FakeCmuxServer(
            workspace_create_indeterminate="applied",
        ) as server:
            with Client(server.path, timeout=1.0) as client:
                result = orchestrate(
                    client,
                    OrchestratorConfig(
                        run_id="indeterminate-applied",
                        request_timeout=1.0,
                        event_ready_timeout=1.0,
                        terminal_wait_timeout_ms=100,
                    ),
                )

            creates = [
                request
                for request in server.requests
                if request["operation"] == "workspace.create"
            ]

        self.assertTrue(result.cleaned_up)
        self.assertEqual(len(creates), 1)
        self.assertIn("session.creation.resolve", server.operations())
        self.assertEqual(
            creates[0]["params"]["correlation_key"],
            creation_key("indeterminate-applied", "workspace.create"),
        )
        self.assertEqual(server.errors, [])

    def test_unapplied_indeterminate_workspace_create_retries_with_new_key(
        self,
    ) -> None:
        with FakeCmuxServer(
            workspace_create_indeterminate="not_applied",
        ) as server:
            with Client(server.path, timeout=1.0) as client:
                result = orchestrate(
                    client,
                    OrchestratorConfig(
                        run_id="indeterminate-unapplied",
                        request_timeout=1.0,
                        event_ready_timeout=1.0,
                        terminal_wait_timeout_ms=100,
                    ),
                )

            creates = [
                request
                for request in server.requests
                if request["operation"] == "workspace.create"
            ]

        self.assertTrue(result.cleaned_up)
        self.assertEqual(len(creates), 2)
        self.assertEqual(
            [request["idempotency_key"] for request in creates],
            [
                mutation_key("indeterminate-unapplied", "workspace.create", 0),
                mutation_key("indeterminate-unapplied", "workspace.create", 1),
            ],
        )
        self.assertEqual(
            {request["params"]["correlation_key"] for request in creates},
            {creation_key("indeterminate-unapplied", "workspace.create")},
        )
        self.assertIn("session.creation.resolve", server.operations())
        self.assertEqual(server.errors, [])

    def test_indeterminate_cleanup_inspects_then_retries(self) -> None:
        with FakeCmuxServer(
            workspace_close_indeterminate="not_applied",
        ) as server:
            with Client(server.path, timeout=1.0) as client:
                result = orchestrate(
                    client,
                    OrchestratorConfig(
                        run_id="cleanup-recovery",
                        request_timeout=1.0,
                        event_ready_timeout=1.0,
                        terminal_wait_timeout_ms=100,
                    ),
                )

            closes = [
                request
                for request in server.requests
                if request["operation"] == "workspace.close"
            ]
            remaining = server.workspace_ids("python-ci-cleanup-recovery")

        self.assertTrue(result.cleaned_up)
        self.assertEqual(remaining, [])
        self.assertEqual(len(closes), 2)
        self.assertNotEqual(
            closes[0]["idempotency_key"],
            closes[1]["idempotency_key"],
        )
        self.assertEqual(server.errors, [])

    def test_applied_indeterminate_topology_create_recovers_exact_path(
        self,
    ) -> None:
        with FakeCmuxServer(
            pane_split_indeterminate="applied",
        ) as server:
            with Client(server.path, timeout=1.0) as client:
                result = orchestrate(
                    client,
                    OrchestratorConfig(
                        run_id="correlated-indeterminate",
                        request_timeout=1.0,
                        event_ready_timeout=1.0,
                        terminal_wait_timeout_ms=100,
                    ),
                )

            splits = [
                request
                for request in server.requests
                if request["operation"] == "pane.split"
            ]
            remaining = server.workspace_ids(
                "python-ci-correlated-indeterminate"
            )

        self.assertTrue(result.cleaned_up)
        self.assertEqual(len(splits), 1)
        self.assertEqual(remaining, [])
        self.assertIn("session.creation.resolve", server.operations())
        self.assertEqual(server.errors, [])

    def test_failed_output_wait_still_cleans_up(self) -> None:
        jobs = list(default_jobs())
        jobs[1] = Job(
            jobs[1].name,
            jobs[1].argv,
            "THIS_PATTERN_NEVER_APPEARS",
        )
        with FakeCmuxServer() as server:
            with Client(server.path, timeout=1.0) as client:
                with self.assertRaisesRegex(
                    OrchestrationError,
                    "did not produce",
                ):
                    orchestrate(
                        client,
                        OrchestratorConfig(
                            run_id="failed-wait",
                            request_timeout=1.0,
                            event_ready_timeout=1.0,
                            terminal_wait_timeout_ms=100,
                            jobs=tuple(jobs),
                        ),
                    )

            remaining = server.workspace_ids("python-ci-failed-wait")

        self.assertEqual(remaining, [])
        self.assertIn("workspace.close", server.operations())
        self.assertIn("stream.cancel", server.operations())
        self.assertEqual(server.errors, [])

    def test_production_example_has_no_raw_or_private_sdk_import(self) -> None:
        root = pathlib.Path(__file__).resolve().parents[1]
        production = (root / "orchestrator.py").read_text(encoding="utf-8")
        self.assertNotIn("cmux.raw", production)
        self.assertNotIn("cmux._", production)
        self.assertNotIn("_connection", production)

        jobs = load_jobs(str(root / "plan.example.json"))
        self.assertEqual([job.name for job in jobs], ["setup", "build", "tests"])


if __name__ == "__main__":
    unittest.main()
