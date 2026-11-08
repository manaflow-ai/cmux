package com.cmux.conformance;

import com.cmux.Client;
import com.cmux.CreatedBrowserPath;
import com.cmux.CreatedPath;
import com.cmux.CreatedTerminalPath;
import com.cmux.CreatedWorkspaceOnly;
import com.cmux.Decimal;
import com.cmux.Ids;
import com.cmux.MutationResult;
import com.cmux.Options;
import com.cmux.RendererGrant;
import com.cmux.ResourceError;
import com.cmux.ResourceStream;
import com.cmux.Secret;
import com.cmux.Selector;
import com.cmux.Session;
import com.cmux.SessionEvent;
import com.cmux.ShellCommand;
import com.cmux.Snapshots;
import com.cmux.StreamEndError;
import com.cmux.StreamItem;
import com.cmux.Workspace;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicLong;

/** Public resource API conformance adapter for the dependency-free Java SDK. */
public final class ResourceAdapter {
    private ResourceAdapter() {}

    public static void main(String[] arguments) throws Exception {
        String input = new BufferedReader(new InputStreamReader(
            System.in, StandardCharsets.UTF_8
        )).readLine();
        Map<String, Object> request = object(MiniJson.parse(input), "request");
        String id = string(request.get("id"), "id");
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("contract_version", 2);
        response.put("id", id);
        try {
            response.put("ok", true);
            response.put("value", dispatch(request));
        } catch (RuntimeException error) {
            response.put("ok", false);
            response.put("error", Map.of(
                "kind", classify(error),
                "message", error.getClass().getSimpleName() + ": " + error.getMessage()
            ));
        }
        System.out.println(MiniJson.stringify(normalize(response)));
    }

    private static Object dispatch(Map<String, Object> request) {
        String operation = string(request.get("op"), "op");
        Map<String, Object> constants = object(request.get("constants"), "constants");
        if (operation.equals("redaction")) {
            return redaction();
        }
        AtomicLong streamSequence = new AtomicLong();
        try (Client client = Client.builder()
                .socket(Path.of(string(request.get("socket_path"), "socket_path")))
                .timeout(Duration.ofSeconds(15))
                .streamIdSource(() -> String.format(
                    "stream_%032x", streamSequence.incrementAndGet()
                ))
                .build()) {
            Session session = session(client, constants);
            Workspace workspace = session.workspace(Selector.id(
                new Ids.WorkspaceId(string(constants.get("workspace"), "workspace"))
            ));
            return switch (operation) {
                case "read" -> read(session);
                case "mutation-replay" -> mutationReplay(workspace, constants);
                case "mutation-error" -> mutationError(workspace, constants);
                case "creation-resolve" -> creationResolve(session, constants);
                case "creation-conflict" -> creationConflict(session, constants);
                case "terminal-wait-exit" ->
                    terminalWaitExit(session, request, constants);
                case "stream-unknown" -> streamUnknown(session);
                case "stream-cancel" -> streamCancel(session);
                case "stream-overflow" -> streamOverflow(session);
                case "live-setup" -> liveSetup(client, request);
                case "live-creation-exit" -> liveCreationExit(client, request);
                case "live-exit-restart" -> liveExitRestart(client, request);
                case "live-restart" -> liveRestart(client, request);
                default -> throw new IllegalArgumentException(
                    "unknown adapter operation " + operation
                );
            };
        }
    }

    private static Session session(Client client, Map<String, Object> constants) {
        return client.machine(Selector.current()).session(Selector.id(
            new Ids.SessionId(string(constants.get("session"), "session"))
        ));
    }

    private static Object read(Session session) {
        var result = session.ping(Options.Read.defaults());
        return Map.of(
            "alive", result.alive(),
            "cursor", cursor(result.cursor())
        );
    }

    private static Options.WorkspaceRename renameOptions(
        Map<String, Object> constants
    ) {
        Options.Mutation mutation = Options.Mutation
            .keyed(string(constants.get("idempotency_key"), "idempotency_key"))
            .expecting(Decimal.parse(string(constants.get("revision"), "revision")));
        return new Options.WorkspaceRename(
            mutation,
            string(constants.get("name"), "name")
        );
    }

    private static Object mutationReplay(
        Workspace workspace,
        Map<String, Object> constants
    ) {
        Options.WorkspaceRename options = renameOptions(constants);
        MutationResult<Snapshots.WorkspaceSnapshot> first = workspace.rename(options);
        MutationResult<Snapshots.WorkspaceSnapshot> second = workspace.rename(options);
        return Map.of(
            "first", mutationValue(first),
            "second", mutationValue(second)
        );
    }

    private static Object mutationValue(
        MutationResult<Snapshots.WorkspaceSnapshot> result
    ) {
        return Map.of(
            "workspace_id", result.value().id().value(),
            "name", result.value().name(),
            "generation", result.generation(),
            "revision", result.revision().toWire(),
            "replayed", result.replayed()
        );
    }

    private static Object mutationError(
        Workspace workspace,
        Map<String, Object> constants
    ) {
        try {
            workspace.rename(renameOptions(constants));
        } catch (ResourceError error) {
            return resourceErrorValue(error);
        }
        throw new IllegalStateException("mutation unexpectedly succeeded");
    }

    private static Object creationResolve(
        Session session,
        Map<String, Object> constants
    ) {
        var resolution = session.resolveCreation(new Options.CreationResolve(
            Options.Read.defaults(),
            string(constants.get("correlation_key"), "correlation_key")
        ));
        return creationResolutionValue(resolution);
    }

    private static Object creationConflict(
        Session session,
        Map<String, Object> constants
    ) {
        try {
            session.createWorkspace(
                Options.WorkspaceCreate.builder()
                    .mutation(Options.Mutation.keyed(string(
                        constants.get("idempotency_key"),
                        "idempotency_key"
                    )))
                    .correlationKey(string(
                        constants.get("correlation_key"),
                        "correlation_key"
                    ))
                    .name(string(constants.get("name"), "name"))
                    .initialContent(Options.InitialContent.EMPTY)
                    .build()
            );
        } catch (ResourceError error) {
            return resourceErrorValue(error);
        }
        throw new IllegalStateException("creation conflict unexpectedly succeeded");
    }

    private static Object terminalWaitExit(
        Session session,
        Map<String, Object> request,
        Map<String, Object> constants
    ) {
        var result = session.terminal(Selector.id(new Ids.TerminalId(
            string(constants.get("terminal"), "terminal")
        ))).waitExit(new Options.WaitExit(
            Options.Read.defaults(),
            Optional.of(Decimal.parse(string(request.get("timeout_ms"), "timeout_ms")))
        ));
        return terminalWaitExitValue(result);
    }

    private static Options.SessionEvents streamOptions() {
        return new Options.SessionEvents(
            Options.Stream.defaults(),
            Optional.empty()
        );
    }

    private static Object streamUnknown(Session session) {
        ResourceStream<SessionEvent> stream = session.events(streamOptions());
        StreamItem<SessionEvent> item = stream.next();
        if (!(item.value() instanceof SessionEvent.Unknown unknown)) {
            throw new IllegalStateException(
                "session event was not the public Unknown variant"
            );
        }
        String end = drainEnd(stream);
        return Map.of(
            "sequence", item.sequence().toWire(),
            "cursor", cursor(item.cursor().orElseThrow(() ->
                new IllegalStateException("stream item omitted cursor")
            )),
            "kind", unknown.kind(),
            "raw", unknown.raw(),
            "end", end
        );
    }

    private static Object streamCancel(Session session) {
        ResourceStream<SessionEvent> stream = session.events(streamOptions());
        stream.close();
        stream.close();
        StreamEndError end = stream.end().orElseThrow(() ->
            new IllegalStateException("cancel omitted terminal stream end")
        );
        return Map.of(
            "end", end.reason(),
            "items_after_cancel", 0,
            "cancel_calls", 2
        );
    }

    private static Object streamOverflow(Session session) {
        ResourceStream<SessionEvent> first = session.events(streamOptions());
        String firstEnd = drainEnd(first);
        ResourceStream<SessionEvent> second = session.events(streamOptions());
        SessionEvent secondValue = second.next().value();
        if (!(secondValue instanceof SessionEvent.Unknown unknown)) {
            throw new IllegalStateException(
                "second stream item was not the public Unknown variant"
            );
        }
        drainEnd(second);
        var control = session.ping(Options.Read.defaults());
        return Map.of(
            "first_end", firstEnd,
            "second_kind", unknown.kind(),
            "control_alive", control.alive()
        );
    }

    private static String drainEnd(ResourceStream<SessionEvent> stream) {
        try {
            while (true) {
                stream.next();
            }
        } catch (StreamEndError end) {
            return end.reason();
        }
    }

    private static Object cursor(com.cmux.Cursor cursor) {
        return Map.of(
            "generation", cursor.generation(),
            "revision", cursor.revision().toWire()
        );
    }

    private static Object redaction() {
        String specifierSecret = "provider://conformance-secret";
        String rendererSecret = "renderer-conformance-secret";
        Secret specifier = new Secret(specifierSecret);
        RendererGrant grant = new RendererGrant(
            "unix:///tmp/renderer",
            new Ids.TerminalId("term_66666666666666666666666666666666"),
            new Secret(rendererSecret),
            List.of("render"),
            1000
        );
        return Map.of(
            "specifier_redacted", !specifier.toString().contains(specifierSecret),
            "renderer_token_redacted", !grant.toString().contains(rendererSecret)
        );
    }

    private static Session liveSession(Client client) {
        return client.machine(Selector.current()).session(Selector.current());
    }

    private static Map<String, String> workspaceRows(Session session) {
        Map<String, String> rows = new LinkedHashMap<>();
        for (Workspace workspace : session.listWorkspaces(Options.Read.defaults())) {
            Snapshots.WorkspaceSnapshot snapshot =
                workspace.cached().orElseGet(workspace::refresh);
            rows.put(snapshot.id().value(), snapshot.name());
        }
        return rows;
    }

    private static Ids.WorkspaceId createEmptyWorkspace(
        Session session,
        String name,
        String key
    ) {
        return session.createWorkspace(
            Options.WorkspaceCreate.builder()
                .mutation(Options.Mutation.keyed(key))
                .name(name)
                .initialContent(Options.InitialContent.EMPTY)
                .build()
        ).value().workspaceId();
    }

    private static Object liveSetup(
        Client client,
        Map<String, Object> request
    ) {
        Session session = liveSession(client);
        boolean pinged = session.ping(Options.Read.defaults()).alive();
        String baseName = string(request.get("workspace_name"), "workspace_name");
        String keyPrefix = string(request.get("key_prefix"), "key_prefix");
        Ids.WorkspaceId stableId = createEmptyWorkspace(
            session,
            baseName,
            keyPrefix + "-stable-create"
        );
        Workspace stable = session.workspace(Selector.id(stableId));
        String stableRenamedName = baseName + "-renamed";
        MutationResult<Snapshots.WorkspaceSnapshot> renamed = stable.rename(
            new Options.WorkspaceRename(
                Options.Mutation.keyed(keyPrefix + "-stable-rename"),
                stableRenamedName
            )
        );

        String duplicateName = baseName + "-duplicate";
        List<Ids.WorkspaceId> duplicateIds = new ArrayList<>();
        duplicateIds.add(createEmptyWorkspace(
            session,
            duplicateName,
            keyPrefix + "-duplicate-a"
        ));
        duplicateIds.add(createEmptyWorkspace(
            session,
            duplicateName,
            keyPrefix + "-duplicate-b"
        ));

        String ambiguityCode;
        List<String> ambiguityCandidates = new ArrayList<>();
        try {
            session.workspace(Selector.name(duplicateName)).rename(
                new Options.WorkspaceRename(
                    Options.Mutation.keyed(keyPrefix + "-ambiguous-rename"),
                    baseName + "-must-not-apply"
                )
            );
            throw new IllegalStateException(
                "duplicate workspace selector unexpectedly mutated"
            );
        } catch (ResourceError error) {
            ambiguityCode = error.code();
            Object candidates = error.details().get("candidates");
            if (candidates instanceof Iterable<?> iterable) {
                for (Object candidate : iterable) {
                    if (candidate instanceof String value) {
                        ambiguityCandidates.add(value);
                    }
                }
            }
        }
        List<String> duplicateValues = duplicateIds.stream()
            .map(Ids.WorkspaceId::value)
            .toList();
        boolean preservedCandidates =
            ambiguityCandidates.size() == duplicateValues.size()
            && new LinkedHashSet<>(ambiguityCandidates)
                .equals(new LinkedHashSet<>(duplicateValues));
        Map<String, String> rows = workspaceRows(session);
        boolean noMutation = duplicateValues.stream().allMatch(identifier ->
            duplicateName.equals(rows.get(identifier))
        ) && !rows.containsValue(baseName + "-must-not-apply");

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("pinged", pinged);
        result.put("stable_id", stableId.value());
        result.put(
            "stable_renamed",
            renamed.value().name().equals(stableRenamedName)
        );
        result.put("duplicate_ids", duplicateValues);
        result.put("ambiguity_code", ambiguityCode);
        result.put(
            "ambiguity_preserved_all_candidates",
            preservedCandidates
        );
        result.put("no_mutation", noMutation);
        return result;
    }

    private static Object liveCreationExit(
        Client client,
        Map<String, Object> request
    ) {
        Session session = liveSession(client);
        Ids.WorkspaceId stableId = new Ids.WorkspaceId(string(
            request.get("expected_stable_id"),
            "expected_stable_id"
        ));
        Workspace workspace = session.workspace(Selector.id(stableId));
        MutationResult<CreatedTerminalPath> screenCreated =
            workspace.createScreen(new Options.ScreenCreate(
                Options.Mutation.keyed(string(
                    request.get("key_prefix"),
                    "key_prefix"
                ) + "-runtime-screen"),
                Optional.empty()
            ));
        CreatedTerminalPath screenPath = screenCreated.value();
        String keyPrefix = string(request.get("key_prefix"), "key_prefix");
        String correlationKey = keyPrefix + "-terminal-correlation";
        var pane = workspace.screen(Selector.id(screenPath.screenId()))
            .pane(Selector.id(screenPath.paneId()));
        MutationResult<CreatedTerminalPath> runResult = pane.run(
            Options.Run.builder(new ShellCommand(string(
                request.get("exit_shell"),
                "exit_shell"
            )))
                .mutation(Options.Mutation.keyed(keyPrefix + "-terminal-run"))
                .correlationKey(correlationKey)
                .build()
        );
        CreatedTerminalPath path = runResult.value();
        var terminal = session.terminal(Selector.id(path.terminalId()));
        Map<String, Object> pending = terminalWaitExitValue(terminal.waitExit(
            waitExitOptions(request, "pending_timeout_ms")
        ));
        var resolution = session.resolveCreation(new Options.CreationResolve(
            Options.Read.defaults(),
            correlationKey
        ));
        if (!resolution.createdPath().orElseThrow().equals(path)) {
            throw new IllegalStateException(
                "creation resolution returned a different terminal path"
            );
        }
        Map<String, Object> creation = creationResolutionValue(resolution);
        Map<String, Object> exited = terminalWaitExitValue(terminal.waitExit(
            waitExitOptions(request, "exit_timeout_ms")
        ));
        Map<String, Object> outcome = object(
            exited.get("outcome"),
            "terminal exit outcome"
        );
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("correlation_key", correlationKey);
        result.put("created_path", createdPathValue(path));
        result.put("pending_terminal_id", pending.get("terminal_id"));
        result.put("pending_state", pending.get("state"));
        result.put("pending_lifecycle", pending.get("lifecycle"));
        result.put("creation_state", creation.get("state"));
        result.put("creation_recovery", creation.get("recovery"));
        result.put("creation_generation", creation.get("generation"));
        result.put("creation_revision", creation.get("revision"));
        result.put("exit_state", exited.get("state"));
        result.put("exit_terminal_id", exited.get("terminal_id"));
        result.put("exit_lifecycle", exited.get("lifecycle"));
        result.put("exit_kind", outcome.get("kind"));
        result.put("exit_code", outcome.get("code"));
        result.put("exited_at", exited.get("exited_at"));
        result.put("exit_revision", exited.get("revision"));
        return result;
    }

    private static Object liveExitRestart(
        Client client,
        Map<String, Object> request
    ) {
        Session session = liveSession(client);
        String correlationKey = string(
            request.get("expected_correlation_key"),
            "expected_correlation_key"
        );
        var resolution = session.resolveCreation(new Options.CreationResolve(
            Options.Read.defaults(),
            correlationKey
        ));
        Map<String, Object> expectedPath = object(
            request.get("expected_created_path"),
            "expected_created_path"
        );
        Ids.TerminalId terminalId = new Ids.TerminalId(string(
            expectedPath.get("terminal_id"),
            "expected_created_path.terminal_id"
        ));
        Map<String, Object> exited = terminalWaitExitValue(
            session.terminal(Selector.id(terminalId)).waitExit(
                waitExitOptions(request, "exit_timeout_ms")
            )
        );
        Map<String, Object> outcome = object(
            exited.get("outcome"),
            "terminal exit outcome"
        );
        Map<String, Object> creation = creationResolutionValue(resolution);
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("correlation_key", creation.get("correlation_key"));
        result.put("created_path", creation.get("created_path"));
        result.put("creation_state", creation.get("state"));
        result.put("creation_recovery", creation.get("recovery"));
        result.put("creation_generation", creation.get("generation"));
        result.put("creation_revision", creation.get("revision"));
        result.put("exit_state", exited.get("state"));
        result.put("exit_terminal_id", exited.get("terminal_id"));
        result.put("exit_lifecycle", exited.get("lifecycle"));
        result.put("exit_kind", outcome.get("kind"));
        result.put("exit_code", outcome.get("code"));
        result.put("exited_at", exited.get("exited_at"));
        result.put("exit_revision", exited.get("revision"));
        return result;
    }

    private static Options.WaitExit waitExitOptions(
        Map<String, Object> request,
        String field
    ) {
        return new Options.WaitExit(
            Options.Read.defaults(),
            Optional.of(Decimal.parse(string(request.get(field), field)))
        );
    }

    private static Object liveRestart(
        Client client,
        Map<String, Object> request
    ) {
        String baseName = string(request.get("workspace_name"), "workspace_name");
        String keyPrefix = string(request.get("key_prefix"), "key_prefix");
        Ids.WorkspaceId stableId = new Ids.WorkspaceId(string(
            request.get("expected_stable_id"), "expected_stable_id"
        ));
        Object duplicateValue = request.get("expected_duplicate_ids");
        if (!(duplicateValue instanceof List<?> duplicateList)
                || duplicateList.size() != 2) {
            throw new IllegalArgumentException(
                "expected_duplicate_ids must contain two IDs"
            );
        }
        List<Ids.WorkspaceId> duplicateIds = duplicateList.stream()
            .map(value -> new Ids.WorkspaceId(
                string(value, "expected_duplicate_id")
            ))
            .toList();
        Session session = liveSession(client);
        Map<String, String> rows = workspaceRows(session);
        List<Ids.WorkspaceId> expectedIds = new ArrayList<>();
        expectedIds.add(stableId);
        expectedIds.addAll(duplicateIds);
        boolean sameIds = expectedIds.stream()
            .allMatch(identifier -> rows.containsKey(identifier.value()));
        boolean stableNamePreserved =
            (baseName + "-renamed").equals(rows.get(stableId.value()));
        boolean duplicatesPreserved = duplicateIds.stream().allMatch(
            identifier -> (baseName + "-duplicate").equals(
                rows.get(identifier.value())
            )
        );

        session.workspace(Selector.id(stableId)).close(
            Options.Mutation.keyed(keyPrefix + "-close-stable")
        );
        session.workspace(Selector.id(duplicateIds.get(0))).close(
            Options.Mutation.keyed(keyPrefix + "-close-a")
        );
        session.workspace(Selector.id(duplicateIds.get(1))).close(
            Options.Mutation.keyed(keyPrefix + "-close-b")
        );
        Map<String, String> remaining = workspaceRows(session);
        boolean disappeared = expectedIds.stream().noneMatch(
            identifier -> remaining.containsKey(identifier.value())
        );
        return Map.of(
            "same_ids", sameIds,
            "stable_name_preserved", stableNamePreserved,
            "duplicates_preserved", duplicatesPreserved,
            "closed", true,
            "disappeared", disappeared
        );
    }

    private static Map<String, Object> resourceErrorValue(
        ResourceError error
    ) {
        return Map.of(
            "code", error.code(),
            "message", error.getMessage(),
            "details", error.details(),
            "retryable", error.retryable()
        );
    }

    private static Map<String, Object> createdPathValue(CreatedPath path) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("workspace_id", path.workspaceId().value());
        if (path instanceof CreatedWorkspaceOnly) {
            result.put("kind", "workspace");
            return result;
        }
        result.put("screen_id", path.screen().orElseThrow().value());
        result.put("pane_id", path.pane().orElseThrow().value());
        result.put("tab_id", path.tab().orElseThrow().value());
        if (path instanceof CreatedTerminalPath) {
            result.put("kind", "terminal");
            result.put("terminal_id", path.terminal().orElseThrow().value());
            return result;
        }
        if (path instanceof CreatedBrowserPath) {
            result.put("kind", "browser");
            result.put("browser_id", path.browser().orElseThrow().value());
            return result;
        }
        throw new IllegalStateException(
            "unsupported created path " + path.getClass().getName()
        );
    }

    private static Map<String, Object> creationResolutionValue(
        com.cmux.Results.CreationResolution resolution
    ) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("correlation_key", resolution.correlationKey());
        result.put("state", lower(resolution.state()));
        result.put("recovery", lower(resolution.recovery()));
        resolution.operation().ifPresent(value ->
            result.put("operation", value)
        );
        resolution.idempotencyKey().ifPresent(value ->
            result.put("idempotency_key", value)
        );
        resolution.createdPath().ifPresent(value ->
            result.put("created_path", createdPathValue(value))
        );
        resolution.generation().ifPresent(value ->
            result.put("generation", value)
        );
        resolution.revision().ifPresent(value ->
            result.put("revision", value.toWire())
        );
        return result;
    }

    private static Map<String, Object> terminalWaitExitValue(
        com.cmux.Results.TerminalWaitExitResult result
    ) {
        Map<String, Object> value = new LinkedHashMap<>();
        if (result instanceof com.cmux.Results.TerminalWaitExitPending pending) {
            value.put("state", "pending");
            value.put("terminal_id", pending.terminalId().value());
            value.put("lifecycle", pending.lifecycle());
            value.put("revision", pending.revision().toWire());
            return value;
        }
        if (result instanceof com.cmux.Results.TerminalWaitExitExited exited) {
            value.put("state", "exited");
            value.put("terminal_id", exited.terminalId().value());
            value.put("lifecycle", "exited");
            value.put("outcome", exitOutcomeValue(exited.outcome()));
            value.put("exited_at", exited.exitedAt().toWire());
            value.put("revision", exited.revision().toWire());
            return value;
        }
        throw new IllegalStateException(
            "unsupported terminal wait result " + result.getClass().getName()
        );
    }

    private static Map<String, Object> exitOutcomeValue(
        com.cmux.Results.TerminalExitOutcome outcome
    ) {
        if (outcome instanceof com.cmux.Results.TerminalExitCode exit) {
            return Map.of("kind", "exit", "code", exit.code());
        }
        if (outcome instanceof com.cmux.Results.TerminalExitSignal signal) {
            return Map.of(
                "kind", "signal",
                "signal", signal.signal(),
                "core_dumped", signal.coreDumped()
            );
        }
        if (outcome instanceof com.cmux.Results.TerminalExitUnknown unknown) {
            return Map.of("kind", "unknown", "reason", unknown.reason());
        }
        throw new IllegalStateException(
            "unsupported terminal exit outcome " + outcome.getClass().getName()
        );
    }

    private static String lower(Enum<?> value) {
        return value.name().toLowerCase(Locale.ROOT);
    }

    private static String classify(RuntimeException error) {
        if (error instanceof ResourceError) {
            return "resource";
        }
        String name = error.getClass().getSimpleName();
        if (name.contains("Transport")) {
            return "transport";
        }
        if (name.contains("Protocol")) {
            return "protocol";
        }
        return "adapter";
    }

    private static Object normalize(Object value) {
        if (value instanceof Decimal decimal) {
            return decimal.toWire();
        }
        if (value instanceof Ids.Id id) {
            return id.value();
        }
        if (value instanceof Optional<?> optional) {
            return optional.map(ResourceAdapter::normalize).orElse(null);
        }
        if (value instanceof BigDecimal decimal) {
            return decimal.scale() <= 0
                ? decimal.toBigIntegerExact()
                : decimal;
        }
        if (value instanceof Map<?, ?> map) {
            Map<String, Object> result = new LinkedHashMap<>();
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                result.put(String.valueOf(entry.getKey()), normalize(entry.getValue()));
            }
            return result;
        }
        if (value instanceof Iterable<?> iterable) {
            List<Object> result = new ArrayList<>();
            for (Object item : iterable) {
                result.add(normalize(item));
            }
            return result;
        }
        return value;
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> object(Object value, String label) {
        if (!(value instanceof Map<?, ?>)) {
            throw new IllegalArgumentException(label + " must be an object");
        }
        return (Map<String, Object>) value;
    }

    private static String string(Object value, String label) {
        if (!(value instanceof String string)) {
            throw new IllegalArgumentException(label + " must be a string");
        }
        return string;
    }
}
