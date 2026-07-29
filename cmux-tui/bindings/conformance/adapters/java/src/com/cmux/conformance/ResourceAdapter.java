package com.cmux.conformance;

import com.cmux.Client;
import com.cmux.Decimal;
import com.cmux.Document;
import com.cmux.ExternalMachineSpecifier;
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
import java.util.List;
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
                case "stream-unknown" -> streamUnknown(session);
                case "stream-cancel" -> streamCancel(session);
                case "stream-overflow" -> streamOverflow(session);
                case "live-flow" -> liveFlow(client, request);
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
        Document result = session.ping(Options.Read.defaults());
        return Map.of(
            "alive", result.fields().get("alive"),
            "cursor", result.fields().get("cursor")
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
            return Map.of(
                "code", error.code(),
                "message", error.getMessage(),
                "details", error.details(),
                "retryable", error.retryable()
            );
        }
        throw new IllegalStateException("mutation unexpectedly succeeded");
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
            "cursor", item.cursor().map(ResourceAdapter::cursor).orElse(null),
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
        Document control = session.ping(Options.Read.defaults());
        return Map.of(
            "first_end", firstEnd,
            "second_kind", unknown.kind(),
            "control_alive", control.fields().get("alive")
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
        ExternalMachineSpecifier specifier =
            new ExternalMachineSpecifier(specifierSecret);
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

    private static Object liveFlow(
        Client client,
        Map<String, Object> request
    ) {
        Session session = client.machine(Selector.current())
            .session(Selector.current());
        boolean pinged = Boolean.TRUE.equals(
            session.ping(Options.Read.defaults()).fields().get("alive")
        );
        String name = string(request.get("workspace_name"), "workspace_name");
        MutationResult<com.cmux.CreatedPath> created = session.createWorkspace(
            Options.WorkspaceCreate.builder()
                .mutation(Options.Mutation.keyed("live-create"))
                .name(name)
                .initialContent(Options.InitialContent.EMPTY)
                .build()
        );
        Ids.WorkspaceId id = created.value().workspace().orElseThrow(() ->
            new IllegalStateException("workspace.create omitted workspace id")
        );
        Workspace workspace = session.workspace(Selector.id(id));
        String renamedName = name + "-renamed";
        MutationResult<Snapshots.WorkspaceSnapshot> renamed = workspace.rename(
            new Options.WorkspaceRename(
                Options.Mutation.keyed("live-rename"),
                renamedName
            )
        );
        boolean listed = session.listWorkspaces(Options.Read.defaults()).stream()
            .anyMatch(item -> item.cached().map(snapshot ->
                snapshot.id().equals(id)
            ).orElse(false));
        workspace.close(Options.Mutation.keyed("live-close"));
        boolean disappeared = session.listWorkspaces(Options.Read.defaults()).stream()
            .noneMatch(item -> item.cached().map(snapshot ->
                snapshot.id().equals(id)
            ).orElse(false));
        return Map.of(
            "pinged", pinged,
            "created", true,
            "renamed", renamed.value().name().equals(renamedName),
            "listed", listed,
            "closed", true,
            "disappeared", disappeared
        );
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
        if (value instanceof Document document) {
            return normalize(document.fields());
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
