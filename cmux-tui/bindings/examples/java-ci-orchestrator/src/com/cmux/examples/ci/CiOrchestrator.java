package com.cmux.examples.ci;

import com.cmux.Client;
import com.cmux.CreatedPath;
import com.cmux.CreatedTerminalPath;
import com.cmux.CreatedWorkspaceOnly;
import com.cmux.Decimal;
import com.cmux.Ids;
import com.cmux.MutationOutcomeUncertain;
import com.cmux.MutationResult;
import com.cmux.Notification;
import com.cmux.Options;
import com.cmux.Render;
import com.cmux.Results;
import com.cmux.Selector;
import com.cmux.Session;
import com.cmux.ShellCommand;
import com.cmux.Snapshots;
import com.cmux.Terminal;
import com.cmux.Transport;
import com.cmux.Workspace;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Objects;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.TimeoutException;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

/**
 * A dependency-free CI task orchestrator built only on the public cmux
 * resource API.
 */
public final class CiOrchestrator {
    private static final int MAX_HISTORY_ROWS = 65_535;
    private static final Pattern SAFE_OPERATION_KEY =
        Pattern.compile("[A-Za-z0-9_-]{1,80}");

    private CiOrchestrator() {}

    public static void main(String[] args) {
        try {
            Config config = Config.parse(args);
            Outcome outcome = execute(config);
            System.out.printf(
                "session=%s workspace=%s terminal=%s exit=%s%n",
                config.session(),
                outcome.workspace().value(),
                outcome.terminal().value(),
                describeExit(outcome.exit().outcome())
            );
            System.out.println("--- screen ---");
            System.out.println(outcome.screen().text());
            System.out.println("--- history ---");
            System.out.println(historyText(outcome.history()));
            outcome.notification().ifPresent(
                id -> System.out.println("notification=" + id.value())
            );
            int processExitCode = outcome.processExitCode();
            if (processExitCode != 0) {
                System.exit(processExitCode);
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
            .timeout(config.timeout().plusMillis(500));
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
        Creation<CreatedWorkspaceOnly> workspaceCreation = createWorkspace(
            session,
            config
        );
        Ids.WorkspaceId workspaceId = workspaceCreation.path().workspaceId();
        Workspace workspace = session.workspace(Selector.id(workspaceId));
        cleanup.arm(workspace);

        Creation<CreatedTerminalPath> terminalCreation = runTerminal(
            session,
            workspace,
            config
        );
        Ids.TerminalId terminalId = terminalCreation.path().terminalId();
        Terminal terminal = session.terminal(Selector.id(terminalId));

        Results.TerminalWaitExitResult waited = terminal.waitExit(
            new Options.WaitExit(
                Options.Read.defaults(),
                Optional.of(Decimal.parse(
                    Long.toString(config.timeout().toMillis())
                ))
            )
        );
        if (waited instanceof Results.TerminalWaitExitPending pending) {
            if (!pending.terminalId().equals(terminalId)) {
                throw new IllegalStateException(
                    "terminal.wait_exit returned the wrong terminal"
                );
            }
            throw new TimeoutException(
                "timed out after " + config.timeout()
                    + " waiting for terminal " + terminalId.value() + " to exit"
            );
        }
        Results.TerminalWaitExitExited exited =
            (Results.TerminalWaitExitExited) waited;
        if (!exited.terminalId().equals(terminalId)) {
            throw new IllegalStateException(
                "terminal.wait_exit returned the wrong terminal"
            );
        }

        Snapshots.TerminalSnapshot terminalSnapshot = terminal.refresh();
        validateExitedSnapshot(terminalSnapshot, exited);
        Results.TerminalScreenResult screen =
            terminal.readScreen(Options.Read.defaults());
        Results.TerminalHistoryResult history = terminal.readHistory(
            new Options.HistoryRead(
                Options.Read.defaults(),
                Optional.empty(),
                Optional.of(MAX_HISTORY_ROWS),
                false
            )
        );

        Optional<Ids.NotificationId> notification = Optional.empty();
        if (!isSuccess(exited.outcome())) {
            notification = notifyFailure(
                session,
                terminalId,
                "cmux CI task failed",
                "Command " + describeExit(exited.outcome())
            );
        }

        return new Outcome(
            workspaceId,
            terminalId,
            exited,
            terminalSnapshot,
            screen,
            history,
            notification,
            workspaceCreation.recovered(),
            terminalCreation.recovered()
        );
    }

    private static Creation<CreatedWorkspaceOnly> createWorkspace(
        Session session,
        Config config
    ) {
        try {
            MutationResult<CreatedPath> result = session.createWorkspace(
                Options.WorkspaceCreate.builder()
                    .mutation(Options.Mutation.keyed(
                        config.workspaceIdempotencyKey()
                    ))
                    .name(config.workspaceName())
                    .initialContent(Options.InitialContent.EMPTY)
                    .correlationKey(config.workspaceCorrelationKey())
                    .build()
            );
            return new Creation<>(
                requirePath(
                    result.value(),
                    CreatedWorkspaceOnly.class,
                    "workspace.create"
                ),
                false
            );
        } catch (MutationOutcomeUncertain uncertain) {
            return new Creation<>(
                recoverPath(
                    session,
                    uncertain,
                    "workspace.create",
                    config.workspaceIdempotencyKey(),
                    config.workspaceCorrelationKey(),
                    CreatedWorkspaceOnly.class
                ),
                true
            );
        }
    }

    private static Creation<CreatedTerminalPath> runTerminal(
        Session session,
        Workspace workspace,
        Config config
    ) {
        Options.Run.Builder run = Options.Run.builder(
            new ShellCommand(config.command())
        )
            .mutation(Options.Mutation.keyed(config.runIdempotencyKey()))
            .name("ci-task")
            .correlationKey(config.runCorrelationKey());
        config.cwd().map(Path::toString).ifPresent(run::cwd);
        try {
            return new Creation<>(workspace.run(run.build()).value(), false);
        } catch (MutationOutcomeUncertain uncertain) {
            return new Creation<>(
                recoverPath(
                    session,
                    uncertain,
                    "workspace.run",
                    config.runIdempotencyKey(),
                    config.runCorrelationKey(),
                    CreatedTerminalPath.class
                ),
                true
            );
        }
    }

    private static <T extends CreatedPath> T recoverPath(
        Session session,
        MutationOutcomeUncertain uncertain,
        String expectedOperation,
        String expectedIdempotencyKey,
        String correlationKey,
        Class<T> pathType
    ) {
        if (!uncertain.operation().equals(expectedOperation)
                || !uncertain.idempotencyKey().equals(expectedIdempotencyKey)) {
            throw new IllegalStateException(
                "unexpected uncertain mutation " + uncertain.operation()
                    + " with key " + uncertain.idempotencyKey(),
                uncertain
            );
        }
        Results.CreationResolution resolution = session.resolveCreation(
            new Options.CreationResolve(
                Options.Read.defaults(),
                correlationKey
            )
        );
        if (!resolution.correlationKey().equals(correlationKey)) {
            throw new IllegalStateException(
                "creation resolution returned a different correlation key"
            );
        }
        if (resolution.state() != Results.CreationState.CREATED) {
            throw new IllegalStateException(
                "creation is " + resolution.state()
                    + "; recovery is " + resolution.recovery()
            );
        }
        resolution.operation().ifPresent(operation -> {
            if (!operation.equals(expectedOperation)) {
                throw new IllegalStateException(
                    "creation correlation resolved to " + operation
                );
            }
        });
        resolution.idempotencyKey().ifPresent(key -> {
            if (!key.equals(expectedIdempotencyKey)) {
                throw new IllegalStateException(
                    "creation correlation resolved to a different idempotency key"
                );
            }
        });
        CreatedPath path = resolution.createdPath().orElseThrow(
            () -> new IllegalStateException(
                "created resolution omitted its created path"
            )
        );
        return requirePath(path, pathType, expectedOperation);
    }

    private static <T extends CreatedPath> T requirePath(
        CreatedPath path,
        Class<T> pathType,
        String operation
    ) {
        if (!pathType.isInstance(path)) {
            throw new IllegalStateException(
                operation + " returned " + path.getClass().getSimpleName()
                    + " instead of " + pathType.getSimpleName()
            );
        }
        return pathType.cast(path);
    }

    private static void validateExitedSnapshot(
        Snapshots.TerminalSnapshot snapshot,
        Results.TerminalWaitExitExited exited
    ) {
        if (!snapshot.id().equals(exited.terminalId())
                || snapshot.lifecycle() != Snapshots.TerminalLifecycle.EXITED
                || snapshot.running()) {
            throw new IllegalStateException(
                "terminal refresh did not return the exited terminal"
            );
        }
        Snapshots.TerminalExit durableExit = snapshot.exit().orElseThrow(
            () -> new IllegalStateException(
                "exited terminal snapshot omitted its durable exit"
            )
        );
        if (!durableExit.outcome().equals(exited.outcome())
                || !durableExit.exitedAt().equals(exited.exitedAt())
                || !durableExit.revision().equals(exited.revision())) {
            throw new IllegalStateException(
                "terminal snapshot exit differs from terminal.wait_exit"
            );
        }
    }

    private static boolean isSuccess(Results.TerminalExitOutcome outcome) {
        return outcome instanceof Results.TerminalExitCode code
            && code.code() == 0;
    }

    private static String describeExit(Results.TerminalExitOutcome outcome) {
        if (outcome instanceof Results.TerminalExitCode code) {
            return "exited with status " + code.code();
        }
        if (outcome instanceof Results.TerminalExitSignal signal) {
            return "terminated by signal " + signal.signal()
                + (signal.coreDumped() ? " with a core dump" : "");
        }
        Results.TerminalExitUnknown unknown =
            (Results.TerminalExitUnknown) outcome;
        return "ended for an unknown reason: " + unknown.reason();
    }

    public static String historyText(Results.TerminalHistoryResult history) {
        return history.rows().stream()
            .map(row -> row.runs().stream()
                .map(Render.Run::text)
                .collect(Collectors.joining()))
            .collect(Collectors.joining("\n"));
    }

    private static Optional<Ids.NotificationId> notifyFailure(
        Session session,
        String title,
        String body
    ) {
        return notifyFailure(session, new Options.NotificationCreate(
            Options.Mutation.defaults(),
            title,
            body,
            Optional.of("error")
        ));
    }

    private static Optional<Ids.NotificationId> notifyFailure(
        Session session,
        Ids.TerminalId terminalId,
        String title,
        String body
    ) {
        return notifyFailure(session, new Options.NotificationCreate(
            Options.Mutation.defaults(),
            title,
            body,
            Optional.of("error"),
            Optional.of(terminalId)
        ));
    }

    private static Optional<Ids.NotificationId> notifyFailure(
        Session session,
        Options.NotificationCreate notification
    ) {
        try {
            MutationResult<Notification> result = session.createNotification(
                notification
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

    private record Creation<T extends CreatedPath>(T path, boolean recovered) {
        private Creation {
            Objects.requireNonNull(path, "path");
        }
    }

    public record Outcome(
        Ids.WorkspaceId workspace,
        Ids.TerminalId terminal,
        Results.TerminalWaitExitExited exit,
        Snapshots.TerminalSnapshot terminalSnapshot,
        Results.TerminalScreenResult screen,
        Results.TerminalHistoryResult history,
        Optional<Ids.NotificationId> notification,
        boolean recoveredWorkspace,
        boolean recoveredTerminal
    ) {
        public Outcome {
            Objects.requireNonNull(workspace, "workspace");
            Objects.requireNonNull(terminal, "terminal");
            Objects.requireNonNull(exit, "exit");
            Objects.requireNonNull(terminalSnapshot, "terminalSnapshot");
            Objects.requireNonNull(screen, "screen");
            Objects.requireNonNull(history, "history");
            Objects.requireNonNull(notification, "notification");
        }

        public int processExitCode() {
            if (exit.outcome() instanceof Results.TerminalExitCode code) {
                return Math.max(0, Math.min(255, code.code()));
            }
            if (exit.outcome() instanceof Results.TerminalExitSignal signal) {
                return Math.min(255, 128 + signal.signal());
            }
            return 2;
        }
    }

    public record Config(
        String session,
        Optional<Path> socketPath,
        Duration timeout,
        String command,
        Optional<Path> cwd,
        String operationKey,
        String workspaceName
    ) {
        public Config {
            Objects.requireNonNull(session, "session");
            Objects.requireNonNull(socketPath, "socketPath");
            Objects.requireNonNull(timeout, "timeout");
            Objects.requireNonNull(command, "command");
            Objects.requireNonNull(cwd, "cwd");
            Objects.requireNonNull(operationKey, "operationKey");
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
            if (!SAFE_OPERATION_KEY.matcher(operationKey).matches()) {
                throw new IllegalArgumentException(
                    "operationKey must contain 1 to 80 ASCII letters, digits, "
                        + "underscores, or hyphens"
                );
            }
            if (workspaceName.isBlank()) {
                throw new IllegalArgumentException("workspaceName must not be blank");
            }
        }

        public String workspaceCorrelationKey() {
            return operationKey + "-workspace";
        }

        public String workspaceIdempotencyKey() {
            return operationKey + "-workspace-attempt-1";
        }

        public String runCorrelationKey() {
            return operationKey + "-run";
        }

        public String runIdempotencyKey() {
            return operationKey + "-run-attempt-1";
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
                "cmux-ci-" + suffix,
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
