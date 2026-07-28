package com.cmux.examples.ci;

import com.cmux.CmuxClient;
import com.cmux.CmuxException;
import com.cmux.UInt64;
import com.cmux.generated.CloseWorkspaceRequest;
import com.cmux.generated.CreateTerminalRequest;
import com.cmux.generated.CreateWorkspaceRequest;
import com.cmux.generated.IdentifyResult;
import com.cmux.generated.NotificationLevel;
import com.cmux.generated.NotifyRequest;
import com.cmux.generated.ReadScreenRequest;
import com.cmux.generated.ReadScreenResult;
import com.cmux.generated.ReadScrollbackRequest;
import com.cmux.generated.ReadScrollbackResult;
import com.cmux.generated.RenderRow;
import com.cmux.generated.RenderRun;
import com.cmux.generated.TerminalPlacement;
import com.cmux.generated.WorkspaceMutationResult;
import java.nio.file.Path;
import java.time.Duration;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.OptionalInt;
import java.util.UUID;
import java.util.concurrent.TimeoutException;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

/**
 * A dependency-free CI/task orchestrator built only on the public cmux Java SDK.
 */
public final class CiOrchestrator {
    private static final int MAX_SCROLLBACK_ROWS = 65_535;
    private static final Pattern SAFE_MARKER = Pattern.compile("[A-Za-z0-9_]+");

    private CiOrchestrator() {}

    public static void main(String[] args) {
        try {
            Config config = Config.parse(args);
            Outcome outcome = execute(config);
            System.out.printf(
                "session=%s workspace=%s surface=%s exit=%d%n",
                outcome.identity().session(),
                outcome.workspace(),
                outcome.surface(),
                outcome.exitCode()
            );
            System.out.println("--- screen ---");
            System.out.println(outcome.screen());
            System.out.println("--- scrollback ---");
            System.out.println(outcome.scrollback());
            if (outcome.notification().isPresent()) {
                System.out.println("notification=" + outcome.notification().orElseThrow());
            }
            if (outcome.exitCode() != 0) {
                System.exit(outcome.exitCode());
            }
        } catch (Exception error) {
            System.err.println("cmux CI orchestration failed: " + usefulMessage(error));
            System.exit(2);
        }
    }

    /**
     * Runs one command in a newly registered workspace and always attempts to
     * tombstone that workspace before returning.
     */
    public static Outcome execute(Config config) throws Exception {
        Objects.requireNonNull(config, "config");
        CmuxClient.Builder clientBuilder = CmuxClient.builder()
            .session(config.session())
            .timeout(config.timeout());
        config.socketPath().ifPresent(clientBuilder::socketPath);

        try (CmuxClient client = clientBuilder.build()) {
            WorkspaceCleanup cleanup = new WorkspaceCleanup(client);
            Thread shutdownHook = new Thread(
                cleanup::closeQuietly,
                "cmux-ci-workspace-cleanup"
            );
            Runtime.getRuntime().addShutdownHook(shutdownHook);

            Outcome outcome = null;
            Exception operationFailure = null;
            try {
                outcome = runCommand(client, cleanup, config);
            } catch (Exception error) {
                operationFailure = error;
                notifyFailure(
                    client,
                    cleanup.surface(),
                    "cmux CI orchestration error",
                    usefulMessage(error)
                );
            } finally {
                try {
                    cleanup.close();
                } catch (CmuxException cleanupError) {
                    if (operationFailure != null) {
                        operationFailure.addSuppressed(cleanupError);
                    } else {
                        operationFailure = cleanupError;
                    }
                }
                removeShutdownHook(shutdownHook);
            }

            if (operationFailure != null) {
                throw operationFailure;
            }
            return Objects.requireNonNull(outcome, "outcome");
        }
    }

    private static Outcome runCommand(
        CmuxClient client,
        WorkspaceCleanup cleanup,
        Config config
    ) throws Exception {
        IdentifyResult identity = client.identify();

        WorkspaceMutationResult workspace = client.createWorkspace(
            CreateWorkspaceRequest.builder()
                .key(config.workspaceKey())
                .name(config.workspaceName())
                .build()
        );
        cleanup.arm(workspace.key());

        CreateTerminalRequest.Builder terminalRequest = CreateTerminalRequest.builder()
            .key(workspace.key())
            .argv(wrapperArgv(config.command(), config.marker()))
            .name("ci-task");
        config.cwd().map(Path::toString).ifPresent(terminalRequest::cwd);
        TerminalPlacement terminal = client.createTerminal(terminalRequest.build());
        cleanup.surface(terminal.surface());

        ReadScreenResult completedScreen = waitForExitMarker(
            client,
            terminal.surface(),
            config.marker(),
            config.timeout(),
            config.pollInterval()
        );
        int exitCode = parseExitCode(completedScreen.text(), config.marker())
            .orElseThrow(() -> new IllegalStateException("exit marker disappeared"));
        ReadScrollbackResult scrollback = client.readScrollback(
            ReadScrollbackRequest.builder()
                .surface(terminal.surface())
                .start(0)
                .count(MAX_SCROLLBACK_ROWS)
                .build()
        );

        Optional<UInt64> notification = Optional.empty();
        if (exitCode != 0) {
            notification = notifyFailure(
                client,
                Optional.of(terminal.surface()),
                "cmux CI task failed",
                "Command exited with status " + exitCode
            );
        }

        return new Outcome(
            identity,
            workspace.workspace(),
            terminal.surface(),
            exitCode,
            completedScreen.text(),
            renderScrollback(scrollback.rows()),
            notification
        );
    }

    private static ReadScreenResult waitForExitMarker(
        CmuxClient client,
        UInt64 surface,
        String marker,
        Duration timeout,
        Duration pollInterval
    ) throws Exception {
        long deadline = System.nanoTime() + timeout.toNanos();
        ReadScreenRequest request = ReadScreenRequest.builder().surface(surface).build();
        while (true) {
            ReadScreenResult screen = client.readScreen(request);
            if (parseExitCode(screen.text(), marker).isPresent()) {
                return screen;
            }

            long remainingNanos = deadline - System.nanoTime();
            if (remainingNanos <= 0) {
                throw new TimeoutException(
                    "timed out after " + timeout + " waiting for marker " + marker
                );
            }
            long sleepNanos = Math.min(pollInterval.toNanos(), remainingNanos);
            try {
                Duration sleep = Duration.ofNanos(sleepNanos);
                Thread.sleep(sleep.toMillis(), sleep.toNanosPart() % 1_000_000);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                throw interrupted;
            }
        }
    }

    private static List<String> wrapperArgv(String command, String marker) {
        String script = """
            set +e
            /bin/sh -lc "$1"
            status=$?
            printf '\\n%s:%s\\n' "$2" "$status"
            exit "$status"
            """;
        return List.of(
            "/bin/sh",
            "-c",
            script,
            "cmux-ci-wrapper",
            command,
            marker
        );
    }

    private static OptionalInt parseExitCode(String text, String marker) {
        Pattern pattern = Pattern.compile(Pattern.quote(marker) + ":([0-9]{1,3})");
        Matcher matcher = pattern.matcher(text);
        OptionalInt result = OptionalInt.empty();
        while (matcher.find()) {
            int value = Integer.parseInt(matcher.group(1));
            if (value <= 255) {
                result = OptionalInt.of(value);
            }
        }
        return result;
    }

    private static String renderScrollback(List<RenderRow> rows) {
        return rows.stream()
            .map(row -> row.runs().stream().map(RenderRun::text).collect(Collectors.joining()))
            .collect(Collectors.joining("\n"));
    }

    private static Optional<UInt64> notifyFailure(
        CmuxClient client,
        Optional<UInt64> surface,
        String title,
        String body
    ) {
        try {
            NotifyRequest.Builder request = NotifyRequest.builder()
                .title(title)
                .body(body)
                .level(NotificationLevel.ERROR);
            surface.ifPresent(request::surface);
            return Optional.of(client.notify(request.build()).notification());
        } catch (CmuxException notificationError) {
            System.err.println(
                "could not post cmux failure notification: " + usefulMessage(notificationError)
            );
            return Optional.empty();
        }
    }

    private static void removeShutdownHook(Thread hook) {
        try {
            Runtime.getRuntime().removeShutdownHook(hook);
        } catch (IllegalStateException ignored) {
            // The hook is already running because the JVM is shutting down.
        }
    }

    private static String usefulMessage(Throwable error) {
        String message = error.getMessage();
        return message == null || message.isBlank()
            ? error.getClass().getSimpleName()
            : message;
    }

    public record Outcome(
        IdentifyResult identity,
        UInt64 workspace,
        UInt64 surface,
        int exitCode,
        String screen,
        String scrollback,
        Optional<UInt64> notification
    ) {
        public Outcome {
            Objects.requireNonNull(identity, "identity");
            Objects.requireNonNull(workspace, "workspace");
            Objects.requireNonNull(surface, "surface");
            Objects.requireNonNull(screen, "screen");
            Objects.requireNonNull(scrollback, "scrollback");
            Objects.requireNonNull(notification, "notification");
            if (exitCode < 0 || exitCode > 255) {
                throw new IllegalArgumentException("exitCode must be in 0..255");
            }
        }
    }

    public record Config(
        String session,
        Optional<Path> socketPath,
        Duration timeout,
        Duration pollInterval,
        String command,
        Optional<Path> cwd,
        String marker,
        String workspaceKey,
        String workspaceName
    ) {
        public Config {
            Objects.requireNonNull(session, "session");
            Objects.requireNonNull(socketPath, "socketPath");
            Objects.requireNonNull(timeout, "timeout");
            Objects.requireNonNull(pollInterval, "pollInterval");
            Objects.requireNonNull(command, "command");
            Objects.requireNonNull(cwd, "cwd");
            Objects.requireNonNull(marker, "marker");
            Objects.requireNonNull(workspaceKey, "workspaceKey");
            Objects.requireNonNull(workspaceName, "workspaceName");
            if (session.isBlank()) {
                throw new IllegalArgumentException("session must not be blank");
            }
            if (timeout.isNegative() || timeout.isZero()) {
                throw new IllegalArgumentException("timeout must be positive");
            }
            if (pollInterval.isNegative() || pollInterval.isZero()) {
                throw new IllegalArgumentException("pollInterval must be positive");
            }
            if (command.isBlank()) {
                throw new IllegalArgumentException("command must not be blank");
            }
            if (!SAFE_MARKER.matcher(marker).matches()) {
                throw new IllegalArgumentException(
                    "marker must contain only ASCII letters, digits, or underscore"
                );
            }
            if (!UUID.fromString(workspaceKey).toString().equals(workspaceKey)) {
                throw new IllegalArgumentException(
                    "workspaceKey must be a lowercase canonical UUID"
                );
            }
            if (workspaceName.isBlank()) {
                throw new IllegalArgumentException("workspaceName must not be blank");
            }
        }

        public static Config parse(String[] args) {
            String session = "main";
            Path socket = null;
            Duration timeout = Duration.ofSeconds(60);
            String command = "printf 'cmux Java SDK CI orchestrator\\n'";
            Path cwd = null;

            for (int index = 0; index < args.length; index++) {
                String argument = args[index];
                switch (argument) {
                    case "--session" -> session = requireValue(args, ++index, argument);
                    case "--socket" -> socket = Path.of(requireValue(args, ++index, argument));
                    case "--timeout-seconds" -> timeout = Duration.ofSeconds(
                        Long.parseLong(requireValue(args, ++index, argument))
                    );
                    case "--command" -> command = requireValue(args, ++index, argument);
                    case "--cwd" -> cwd = Path.of(requireValue(args, ++index, argument));
                    case "--help" -> {
                        printUsage();
                        System.exit(0);
                    }
                    default -> throw new IllegalArgumentException(
                        "unknown argument " + argument
                    );
                }
            }

            String suffix = UUID.randomUUID().toString().replace("-", "");
            String marker = "CMUX_CI_" + suffix;
            String workspaceKey = UUID.randomUUID().toString();
            return new Config(
                session,
                Optional.ofNullable(socket),
                timeout,
                Duration.ofMillis(100),
                command,
                Optional.ofNullable(cwd),
                marker,
                workspaceKey,
                "cmux-ci-" + suffix.substring(0, 8)
            );
        }

        private static String requireValue(String[] args, int index, String option) {
            if (index >= args.length) {
                throw new IllegalArgumentException(option + " requires a value");
            }
            return args[index];
        }

        private static void printUsage() {
            System.out.println(
                "Usage: java-ci-orchestrator [--session NAME] [--socket PATH] "
                    + "[--timeout-seconds N] [--cwd PATH] [--command SHELL]"
            );
        }
    }

    private static final class WorkspaceCleanup {
        private final CmuxClient client;
        private boolean closed;
        private volatile String workspaceKey;
        private volatile UInt64 surface;

        private WorkspaceCleanup(CmuxClient client) {
            this.client = client;
        }

        private void arm(String key) {
            workspaceKey = key;
        }

        private void surface(UInt64 value) {
            surface = value;
        }

        private Optional<UInt64> surface() {
            return Optional.ofNullable(surface);
        }

        private synchronized void close() throws CmuxException {
            String key = workspaceKey;
            if (key != null && !closed) {
                client.closeWorkspace(CloseWorkspaceRequest.builder().key(key).build());
                closed = true;
            }
        }

        private void closeQuietly() {
            try {
                close();
            } catch (CmuxException cleanupError) {
                System.err.println(
                    "could not clean up cmux CI workspace: " + usefulMessage(cleanupError)
                );
            }
        }
    }
}
