package com.cmux.examples.ci;

import com.cmux.Client;
import com.cmux.Command;
import com.cmux.CreatedPath;
import com.cmux.Document;
import com.cmux.ExactCommand;
import com.cmux.Ids;
import com.cmux.MutationResult;
import com.cmux.Notification;
import com.cmux.Options;
import com.cmux.Selector;
import com.cmux.Session;
import com.cmux.Terminal;
import com.cmux.Transport;
import com.cmux.Workspace;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Objects;
import java.util.Optional;
import java.util.OptionalInt;
import java.util.UUID;
import java.util.concurrent.TimeoutException;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * A dependency-free CI task orchestrator built only on the public cmux
 * resource API.
 */
public final class CiOrchestrator {
    private static final int MAX_HISTORY_ROWS = 65_535;
    private static final Pattern SAFE_MARKER = Pattern.compile("[A-Za-z0-9_]+");

    private CiOrchestrator() {}

    public static void main(String[] args) {
        try {
            Config config = Config.parse(args);
            Outcome outcome = execute(config);
            System.out.printf(
                "session=%s workspace=%s terminal=%s exit=%d%n",
                config.session(),
                outcome.workspace().value(),
                outcome.terminal().value(),
                outcome.exitCode()
            );
            System.out.println("--- screen ---");
            System.out.println(outcome.screen());
            System.out.println("--- history ---");
            System.out.println(outcome.history());
            outcome.notification().ifPresent(
                id -> System.out.println("notification=" + id.value())
            );
            if (outcome.exitCode() != 0) {
                System.exit(outcome.exitCode());
            }
        } catch (Exception error) {
            System.err.println("cmux CI orchestration failed: " + usefulMessage(error));
            System.exit(2);
        }
    }

    /**
     * Runs one command in a new workspace and always attempts to close that
     * workspace before returning.
     */
    public static Outcome execute(Config config) throws Exception {
        return execute(config, null);
    }

    static Outcome execute(Config config, Transport transport) throws Exception {
        Objects.requireNonNull(config, "config");
        Client.Builder builder = Client.builder()
            .session(config.session())
            .timeout(config.timeout().plusSeconds(1));
        config.socketPath().ifPresent(builder::socket);
        if (transport != null) {
            builder.transport(transport);
        }

        try (Client client = builder.build()) {
            Session session = client.machine(Selector.current())
                .session(Selector.current());
            WorkspaceCleanup cleanup = new WorkspaceCleanup();
            Thread shutdownHook = new Thread(
                cleanup::closeQuietly,
                "cmux-ci-workspace-cleanup"
            );
            Runtime.getRuntime().addShutdownHook(shutdownHook);

            Outcome outcome = null;
            Exception operationFailure = null;
            try {
                outcome = runCommand(session, cleanup, config);
            } catch (Exception error) {
                operationFailure = error;
                notifyFailure(
                    session,
                    "cmux CI orchestration error",
                    usefulMessage(error)
                );
            } finally {
                try {
                    cleanup.close();
                } catch (RuntimeException cleanupError) {
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
        Session session,
        WorkspaceCleanup cleanup,
        Config config
    ) throws Exception {
        MutationResult<CreatedPath> createdWorkspace = session.createWorkspace(
            Options.WorkspaceCreate.builder()
                .name(config.workspaceName())
                .initialContent(Options.InitialContent.EMPTY)
                .build()
        );
        Ids.WorkspaceId workspaceId = createdWorkspace.value()
            .workspace()
            .orElseThrow(() -> new IllegalStateException(
                "workspace.create omitted the workspace ID"
            ));
        Workspace workspace = session.workspace(Selector.id(workspaceId));
        cleanup.arm(workspace);

        Options.Run.Builder run = Options.Run.builder(wrapperCommand(config))
            .name("ci-task");
        config.cwd().map(Path::toString).ifPresent(run::cwd);
        CreatedPath createdTerminal = workspace.run(run.build()).value();
        Ids.TerminalId terminalId = createdTerminal.terminal().orElseThrow(
            () -> new IllegalStateException("workspace.run omitted the terminal ID")
        );
        Terminal terminal = session.terminal(Selector.id(terminalId));

        String completionPattern =
            Pattern.quote(config.marker()) + ":[0-9]{1,3}";
        Document waited = terminal.waitFor(new Options.Wait(
            Options.Read.defaults(),
            completionPattern,
            config.timeout().toMillis()
        ));
        String waitText = documentText(waited, "terminal.wait");
        if (!Boolean.TRUE.equals(waited.fields().get("matched"))) {
            throw new TimeoutException(
                "timed out after " + config.timeout()
                    + " waiting for marker " + config.marker()
            );
        }
        int exitCode = parseExitCode(waitText, config.marker()).orElseThrow(
            () -> new IllegalStateException("terminal.wait omitted the exit marker")
        );

        String screen = documentText(
            terminal.readScreen(Options.Read.defaults()),
            "terminal.screen.read"
        );
        String history = documentText(
            terminal.readHistory(new Options.HistoryRead(
                Options.Read.defaults(),
                Optional.empty(),
                Optional.of(MAX_HISTORY_ROWS),
                false
            )),
            "terminal.history.read"
        );

        Optional<Ids.NotificationId> notification = Optional.empty();
        if (exitCode != 0) {
            notification = notifyFailure(
                session,
                "cmux CI task failed",
                "Command exited with status " + exitCode
            );
        }

        return new Outcome(
            workspaceId,
            terminalId,
            exitCode,
            screen,
            history,
            notification
        );
    }

    private static Command wrapperCommand(Config config) {
        String script = """
            set +e
            /bin/sh -lc "$1"
            status=$?
            printf '\\n%s:%s\\n' "$2" "$status"
            exit "$status"
            """;
        return ExactCommand.of(
            "/bin/sh",
            "-c",
            script,
            "cmux-ci-wrapper",
            config.command(),
            config.marker()
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

    private static String documentText(Document document, String operation) {
        Object text = document.fields().get("text");
        if (text instanceof String value) {
            return value;
        }
        throw new IllegalStateException(operation + " result omitted text");
    }

    private static Optional<Ids.NotificationId> notifyFailure(
        Session session,
        String title,
        String body
    ) {
        try {
            MutationResult<Notification> result = session.createNotification(
                new Options.NotificationCreate(
                    Options.Mutation.defaults(),
                    title,
                    body,
                    Optional.of("error")
                )
            );
            return Optional.of(result.value().snapshot().id());
        } catch (RuntimeException notificationError) {
            System.err.println(
                "could not post cmux failure notification: "
                    + usefulMessage(notificationError)
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
        Ids.WorkspaceId workspace,
        Ids.TerminalId terminal,
        int exitCode,
        String screen,
        String history,
        Optional<Ids.NotificationId> notification
    ) {
        public Outcome {
            Objects.requireNonNull(workspace, "workspace");
            Objects.requireNonNull(terminal, "terminal");
            Objects.requireNonNull(screen, "screen");
            Objects.requireNonNull(history, "history");
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
        String command,
        Optional<Path> cwd,
        String marker,
        String workspaceName
    ) {
        public Config {
            Objects.requireNonNull(session, "session");
            Objects.requireNonNull(socketPath, "socketPath");
            Objects.requireNonNull(timeout, "timeout");
            Objects.requireNonNull(command, "command");
            Objects.requireNonNull(cwd, "cwd");
            Objects.requireNonNull(marker, "marker");
            Objects.requireNonNull(workspaceName, "workspaceName");
            if (session.isBlank()) {
                throw new IllegalArgumentException("session must not be blank");
            }
            if (timeout.isNegative() || timeout.isZero()) {
                throw new IllegalArgumentException("timeout must be positive");
            }
            if (command.isBlank()) {
                throw new IllegalArgumentException("command must not be blank");
            }
            if (!SAFE_MARKER.matcher(marker).matches()) {
                throw new IllegalArgumentException(
                    "marker must contain only ASCII letters, digits, or underscore"
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
            return new Config(
                session,
                Optional.ofNullable(socket),
                timeout,
                command,
                Optional.ofNullable(cwd),
                "CMUX_CI_" + suffix,
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
        private Workspace workspace;
        private boolean closed;

        private synchronized void arm(Workspace value) {
            workspace = Objects.requireNonNull(value, "value");
        }

        private synchronized void close() {
            if (workspace != null && !closed) {
                workspace.close(Options.Mutation.defaults());
                closed = true;
            }
        }

        private void closeQuietly() {
            try {
                close();
            } catch (RuntimeException cleanupError) {
                System.err.println(
                    "could not clean up cmux CI workspace: "
                        + usefulMessage(cleanupError)
                );
            }
        }
    }
}
