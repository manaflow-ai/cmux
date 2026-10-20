package com.cmux.examples.ci;

import com.cmux.Ids;
import com.cmux.Results;
import com.cmux.Snapshots;
import java.time.Duration;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.TimeoutException;

public final class CiOrchestratorIntegrationTest {
    private static final String OPERATION_KEY = "cmux-ci-deterministic";
    private static final String COMMAND = "printf 'compile ok\\n'";

    private CiOrchestratorIntegrationTest() {}

    public static void main(String[] args) throws Exception {
        successCapturesTypedOutputAndCleansUp();
        commandFailureUsesExactExitAndCleansUp();
        timeoutNotifiesAndCleansUp();
        lostRunResponseRecoversByCorrelation();
        System.out.println("CiOrchestratorIntegrationTest passed");
    }

    private static void successCapturesTypedOutputAndCleansUp()
            throws Exception {
        try (FakeCmuxServer server = fake(FakeCmuxServer.Scenario.SUCCESS)) {
            CiOrchestrator.Outcome outcome =
                CiOrchestrator.execute(config(Duration.ofSeconds(2)), server);
            require(outcome.processExitCode() == 0, "success exit code");
            require(
                outcome.exit().outcome() instanceof
                    Results.TerminalExitCode code && code.code() == 0,
                "typed success exit outcome"
            );
            require(
                outcome.workspace().equals(
                    new Ids.WorkspaceId(FakeCmuxServer.WORKSPACE_ID)
                ),
                "workspace id"
            );
            require(
                outcome.terminal().equals(
                    new Ids.TerminalId(FakeCmuxServer.TERMINAL_ID)
                ),
                "terminal id"
            );
            require(
                outcome.screen().text().equals("compile ok")
                    && outcome.screen().cols() == 80
                    && outcome.screen().rows() == 24,
                "typed screen"
            );
            require(
                CiOrchestrator.historyText(outcome.history()).equals(
                    "compile started\ncompile ok"
                ),
                "typed history rows"
            );
            require(
                outcome.terminalSnapshot().lifecycle()
                    == Snapshots.TerminalLifecycle.EXITED
                    && outcome.terminalSnapshot().exit().isPresent(),
                "durable terminal lifecycle"
            );
            require(outcome.notification().isEmpty(), "success notification");
            require(!outcome.recoveredWorkspace(), "workspace not recovered");
            require(!outcome.recoveredTerminal(), "terminal not recovered");
            require(
                server.operations().equals(
                    List.of(
                        "workspace.create",
                        "workspace.run",
                        "terminal.wait_exit",
                        "terminal.get",
                        "terminal.screen.read",
                        "terminal.history.read",
                        "workspace.close"
                    )
                ),
                "success operation sequence: " + server.operations()
            );
        }
    }

    private static void commandFailureUsesExactExitAndCleansUp()
            throws Exception {
        try (FakeCmuxServer server = fake(
            FakeCmuxServer.Scenario.COMMAND_FAILURE
        )) {
            CiOrchestrator.Outcome outcome =
                CiOrchestrator.execute(config(Duration.ofSeconds(2)), server);
            require(outcome.processExitCode() == 7, "failure exit code");
            require(
                outcome.exit().outcome() instanceof
                    Results.TerminalExitCode code && code.code() == 7,
                "typed failure exit outcome"
            );
            require(
                outcome.screen().text().equals("test failed"),
                "failure screen"
            );
            require(
                CiOrchestrator.historyText(outcome.history()).equals(
                    "tests started\ntest failed"
                ),
                "failure history"
            );
            require(
                outcome.notification().equals(
                    Optional.of(
                        new Ids.NotificationId(FakeCmuxServer.NOTIFICATION_ID)
                    )
                ),
                "failure notification"
            );
            require(
                server.operations().equals(
                    List.of(
                        "workspace.create",
                        "workspace.run",
                        "terminal.wait_exit",
                        "terminal.get",
                        "terminal.screen.read",
                        "terminal.history.read",
                        "notification.create",
                        "workspace.close"
                    )
                ),
                "failure operation sequence: " + server.operations()
            );
        }
    }

    private static void timeoutNotifiesAndCleansUp() throws Exception {
        try (FakeCmuxServer server = fake(FakeCmuxServer.Scenario.TIMEOUT)) {
            try {
                CiOrchestrator.execute(config(Duration.ofMillis(60)), server);
                throw new AssertionError("timeout scenario unexpectedly succeeded");
            } catch (TimeoutException expected) {
                require(
                    expected.getMessage().contains(
                        FakeCmuxServer.TERMINAL_ID
                    ),
                    "timeout names the terminal"
                );
            }
            require(
                server.operations().equals(
                    List.of(
                        "workspace.create",
                        "workspace.run",
                        "terminal.wait_exit",
                        "notification.create",
                        "workspace.close"
                    )
                ),
                "timeout operation sequence: " + server.operations()
            );
        }
    }

    private static void lostRunResponseRecoversByCorrelation()
            throws Exception {
        try (FakeCmuxServer server = fake(
            FakeCmuxServer.Scenario.RUN_RESPONSE_LOSS
        )) {
            CiOrchestrator.Outcome outcome =
                CiOrchestrator.execute(config(Duration.ofMillis(60)), server);
            require(outcome.processExitCode() == 0, "recovered exit code");
            require(!outcome.recoveredWorkspace(), "workspace response received");
            require(outcome.recoveredTerminal(), "terminal path recovered");
            require(
                outcome.terminal().equals(
                    new Ids.TerminalId(FakeCmuxServer.TERMINAL_ID)
                ),
                "recovered opaque terminal id"
            );
            require(
                server.operations().equals(
                    List.of(
                        "workspace.create",
                        "workspace.run",
                        "session.creation.resolve",
                        "terminal.wait_exit",
                        "terminal.get",
                        "terminal.screen.read",
                        "terminal.history.read",
                        "workspace.close"
                    )
                ),
                "recovery operation sequence: " + server.operations()
            );
        }
    }

    private static FakeCmuxServer fake(FakeCmuxServer.Scenario scenario) {
        return new FakeCmuxServer(scenario, OPERATION_KEY, COMMAND);
    }

    private static CiOrchestrator.Config config(Duration timeout) {
        return new CiOrchestrator.Config(
            "fake-ci",
            Optional.empty(),
            timeout,
            COMMAND,
            Optional.empty(),
            OPERATION_KEY,
            "cmux-ci-test"
        );
    }

    private static void require(boolean condition, String label) {
        if (!condition) {
            throw new AssertionError(label);
        }
    }
}
