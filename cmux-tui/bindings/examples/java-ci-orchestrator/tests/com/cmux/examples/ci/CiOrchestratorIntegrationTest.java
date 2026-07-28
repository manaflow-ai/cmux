package com.cmux.examples.ci;

import com.cmux.UInt64;
import java.nio.file.Path;
import java.time.Duration;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.TimeoutException;

public final class CiOrchestratorIntegrationTest {
    private static final String MARKER = "CMUX_CI_DETERMINISTIC";
    private static final String WORKSPACE_KEY = "123e4567-e89b-12d3-a456-426614174000";
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
            CiOrchestrator.Outcome outcome = CiOrchestrator.execute(config(server.socketPath()));
            require(outcome.exitCode() == 0, "success exit code");
            require(outcome.identity().protocol() == 10, "identify protocol");
            require(outcome.workspace().equals(UInt64.of(11)), "workspace id");
            require(outcome.surface().equals(UInt64.of(31)), "surface id");
            require(outcome.screen().contains(MARKER + ":0"), "screen marker");
            require(outcome.scrollback().equals("compile started"), "scrollback text");
            require(outcome.notification().isEmpty(), "success notification");
            server.await();
            require(
                server.commands().equals(
                    List.of(
                        "identify",
                        "create-workspace",
                        "create-terminal",
                        "read-screen",
                        "read-scrollback",
                        "close-workspace"
                    )
                ),
                "success command sequence: " + server.commands()
            );
        }
    }

    private static void commandFailureNotifiesAndCleansUp() throws Exception {
        try (FakeCmuxServer server = fake(FakeCmuxServer.Scenario.COMMAND_FAILURE)) {
            CiOrchestrator.Outcome outcome = CiOrchestrator.execute(config(server.socketPath()));
            require(outcome.exitCode() == 7, "failure exit code");
            require(outcome.screen().contains(MARKER + ":7"), "failure marker");
            require(outcome.scrollback().equals("tests started"), "failure scrollback");
            require(
                outcome.notification().equals(Optional.of(UInt64.of(44))),
                "failure notification"
            );
            server.await();
            require(
                server.commands().equals(
                    List.of(
                        "identify",
                        "create-workspace",
                        "create-terminal",
                        "read-screen",
                        "read-scrollback",
                        "notify",
                        "close-workspace"
                    )
                ),
                "failure command sequence: " + server.commands()
            );
        }
    }

    private static void timeoutNotifiesAndCleansUp() throws Exception {
        try (FakeCmuxServer server = fake(FakeCmuxServer.Scenario.TIMEOUT)) {
            CiOrchestrator.Config config = new CiOrchestrator.Config(
                "fake-ci",
                Optional.of(server.socketPath()),
                Duration.ofMillis(60),
                Duration.ofMillis(5),
                COMMAND,
                Optional.empty(),
                MARKER,
                WORKSPACE_KEY,
                "cmux-ci-test"
            );
            try {
                CiOrchestrator.execute(config);
                throw new AssertionError("timeout scenario unexpectedly succeeded");
            } catch (TimeoutException expected) {
                require(
                    expected.getMessage().contains(MARKER),
                    "timeout names the marker"
                );
            }
            server.await();
            require(server.readScreenCount() >= 2, "timeout polls more than once");
            List<String> commands = server.commands();
            require(commands.get(0).equals("identify"), "timeout identifies first");
            require(commands.contains("notify"), "timeout posts notification");
            require(
                commands.get(commands.size() - 1).equals("close-workspace"),
                "timeout cleans up last"
            );
            require(!commands.contains("read-scrollback"), "timeout skips scrollback");
        }
    }

    private static FakeCmuxServer fake(FakeCmuxServer.Scenario scenario) throws Exception {
        return new FakeCmuxServer(scenario, MARKER, WORKSPACE_KEY, COMMAND);
    }

    private static CiOrchestrator.Config config(Path socketPath) {
        return new CiOrchestrator.Config(
            "fake-ci",
            Optional.of(socketPath),
            Duration.ofSeconds(2),
            Duration.ofMillis(5),
            COMMAND,
            Optional.empty(),
            MARKER,
            WORKSPACE_KEY,
            "cmux-ci-test"
        );
    }

    private static void require(boolean condition, String label) {
        if (!condition) {
            throw new AssertionError(label);
        }
    }
}
