package com.cmux.examples.ci;

import com.cmux.Ids;
import java.time.Duration;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.TimeoutException;

public final class CiOrchestratorIntegrationTest {
    private static final String MARKER = "CMUX_CI_DETERMINISTIC";
    private static final String COMMAND = "printf 'compile ok\\n'";

    private CiOrchestratorIntegrationTest() {}

    public static void main(String[] args) throws Exception {
        successCapturesOutputAndCleansUp();
        commandFailureNotifiesAndCleansUp();
        timeoutNotifiesAndCleansUp();
        System.out.println("CiOrchestratorIntegrationTest passed");
    }

    private static void successCapturesOutputAndCleansUp() throws Exception {
        try (FakeCmuxServer server = fake(FakeCmuxServer.Scenario.SUCCESS)) {
            CiOrchestrator.Outcome outcome =
                CiOrchestrator.execute(config(Duration.ofSeconds(2)), server);
            require(outcome.exitCode() == 0, "success exit code");
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
            require(outcome.screen().equals("compile ok"), "screen text");
            require(
                outcome.history().equals("compile started\ncompile ok"),
                "history text"
            );
            require(outcome.notification().isEmpty(), "success notification");
            require(
                server.operations().equals(
                    List.of(
                        "workspace.create",
                        "workspace.run",
                        "terminal.wait",
                        "terminal.screen.read",
                        "terminal.history.read",
                        "workspace.close"
                    )
                ),
                "success operation sequence: " + server.operations()
            );
        }
    }

    private static void commandFailureNotifiesAndCleansUp() throws Exception {
        try (FakeCmuxServer server = fake(
            FakeCmuxServer.Scenario.COMMAND_FAILURE
        )) {
            CiOrchestrator.Outcome outcome =
                CiOrchestrator.execute(config(Duration.ofSeconds(2)), server);
            require(outcome.exitCode() == 7, "failure exit code");
            require(outcome.screen().equals("test failed"), "failure screen");
            require(
                outcome.history().equals("tests started\ntest failed"),
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
                        "terminal.wait",
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
                    expected.getMessage().contains(MARKER),
                    "timeout names the marker"
                );
            }
            require(
                server.operations().equals(
                    List.of(
                        "workspace.create",
                        "workspace.run",
                        "terminal.wait",
                        "notification.create",
                        "workspace.close"
                    )
                ),
                "timeout operation sequence: " + server.operations()
            );
        }
    }

    private static FakeCmuxServer fake(FakeCmuxServer.Scenario scenario) {
        return new FakeCmuxServer(scenario, MARKER, COMMAND);
    }

    private static CiOrchestrator.Config config(Duration timeout) {
        return new CiOrchestrator.Config(
            "fake-ci",
            Optional.empty(),
            timeout,
            COMMAND,
            Optional.empty(),
            MARKER,
            "cmux-ci-test"
        );
    }

    private static void require(boolean condition, String label) {
        if (!condition) {
            throw new AssertionError(label);
        }
    }
}
