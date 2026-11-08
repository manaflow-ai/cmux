package com.cmux.conformance;

import com.cmux.raw.Bytes;
import com.cmux.raw.CmuxAuthorityException;
import com.cmux.raw.CmuxClient;
import com.cmux.raw.CmuxCommandException;
import com.cmux.raw.CmuxDecodeException;
import com.cmux.raw.CmuxStream;
import com.cmux.raw.CmuxTimeoutException;
import com.cmux.raw.Json;
import com.cmux.raw.UInt64;
import com.cmux.raw.Authority;
import com.cmux.raw.ClientChangedEvent;
import com.cmux.raw.CommandMetadata;
import com.cmux.raw.Commands;
import com.cmux.raw.CreateTerminalRequest;
import com.cmux.raw.EventMetadata;
import com.cmux.raw.Events;
import com.cmux.raw.MarkWorkspacesProviderManagedRequest;
import com.cmux.raw.OutputEvent;
import com.cmux.raw.PairingResponseRequest;
import com.cmux.raw.ProtocolEvent;
import com.cmux.raw.SetClientInfoRequest;
import com.cmux.raw.UnknownEvent;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Protocol-10 conformance adapter for the public Java SDK. */
public final class Adapter {
    private Adapter() {}

    public static void main(String[] args) throws Exception {
        BufferedReader reader = new BufferedReader(
            new InputStreamReader(System.in, StandardCharsets.UTF_8)
        );
        @SuppressWarnings("unchecked")
        Map<String, Object> request = (Map<String, Object>) Json.parse(reader.readLine());
        LinkedHashMap<String, Object> response = new LinkedHashMap<>();
        response.put("contract_version", 1);
        response.put("id", request.get("id"));
        try {
            response.put("value", dispatch(request));
            response.put("ok", true);
        } catch (Throwable error) {
            response.put("ok", false);
            response.put(
                "error",
                Map.of("kind", classify(error), "message", String.valueOf(error.getMessage()))
            );
        }
        System.out.println(Json.stringify(response));
    }

    private static Object dispatch(Map<String, Object> request) throws Exception {
        return switch (string(request, "op", "")) {
            case "metadata" -> metadata();
            case "identify" -> identify(request);
            case "nullable-literal" -> nullableLiteral(request);
            case "optional-non-null-response" -> optionalNonNullResponse(request);
            case "optional-nullable-request" -> optionalNullableRequest(request);
            case "stream" -> stream(request);
            case "required-nullable-event" -> requiredNullableEvent(request);
            case "optional-non-null-event" -> optionalNonNullEvent(request);
            case "close-pending-stream" -> closePendingStream(request);
            case "authority" -> authority(request);
            case "authority-denied" -> authorityDenied(request);
            case "real-flow" -> realFlow(request);
            default -> throw new IllegalArgumentException(
                "unknown adapter operation " + request.get("op")
            );
        };
    }

    private static Object metadata() {
        List<Object> commands = new ArrayList<>();
        for (CommandMetadata item : Commands.ALL.values()) {
            commands.add(
                Map.of(
                    "name",
                    item.wireName(),
                    "authority",
                    item.authority().wireValue(),
                    "stream",
                    item.streamKind().name().toLowerCase()
                )
            );
        }
        List<Object> events = new ArrayList<>();
        for (EventMetadata item : Events.ALL.values()) {
            events.add(Map.of("name", item.wireName(), "streams", item.streams()));
        }
        return Map.of("commands", commands, "events", events);
    }

    private static CmuxClient client(Map<String, Object> request) throws Exception {
        return client(request, false);
    }

    private static CmuxClient client(
        Map<String, Object> request,
        boolean enableProviderAuthority
    ) throws Exception {
        long timeout = number(request, "timeout_ms", 1000);
        int maxFrame = Math.toIntExact(number(request, "max_frame_bytes", 16 * 1024 * 1024));
        int maxEvents = Math.toIntExact(number(request, "max_buffered_events", 256));
        CmuxClient.Builder builder = CmuxClient.builder()
            .socketPath(string(request, "socket_path", ""))
            .timeout(Duration.ofMillis(Math.max(timeout, 1)))
            .maxResponseBytes(maxFrame)
            .maxBufferedStreamEvents(maxEvents);
        if (enableProviderAuthority) {
            builder.enableProviderAuthority();
        }
        return builder.build();
    }

    private static Object identify(Map<String, Object> request) throws Exception {
        try (CmuxClient client = client(request)) {
            var value = client.identify();
            return Map.of(
                "app",
                value.app(),
                "protocol",
                value.protocol(),
                "workspace_revision",
                value.workspaceRevision().toString(),
                "terminal_revision",
                value.terminalRevision().toString()
            );
        }
    }

    private static Object nullableLiteral(Map<String, Object> request) throws Exception {
        try (CmuxClient client = client(request)) {
            var placement = client.createTerminal(
                CreateTerminalRequest.builder().key("workspace-key").build()
            );
            LinkedHashMap<String, Object> result = new LinkedHashMap<>();
            result.put("lifecycle", placement.lifecycle().wireValue());
            return result;
        }
    }

    private static Object optionalNonNullResponse(Map<String, Object> request) throws Exception {
        try (CmuxClient client = client(request)) {
            var value = client.identify();
            return Map.of("present", value.capabilities().isPresent());
        }
    }

    private static Object optionalNullableRequest(Map<String, Object> request) throws Exception {
        String presence = string(request, "presence", "");
        SetClientInfoRequest.Builder builder = SetClientInfoRequest.builder();
        switch (presence) {
            case "omitted" -> {
                // The untouched builder preserves the omitted state.
            }
            case "null" -> builder.name(null);
            case "value" -> builder.name("conformance-client");
            default -> throw new IllegalArgumentException("unknown presence " + presence);
        }
        try (CmuxClient client = client(request)) {
            client.setClientInfo(builder.build());
            return Map.of("presence", presence);
        }
    }

    private static CmuxStream<? extends ProtocolEvent> openStream(
        CmuxClient client,
        Map<String, Object> request
    ) throws Exception {
        String kind = string(request, "stream", "");
        UInt64 surface = UInt64.parse(string(request, "surface", "7"));
        return switch (kind) {
            case "subscribe-coarse" -> client.subscribeEvents();
            case "subscribe-deltas" -> client.subscribeDeltas();
            case "attach-byte" -> client.attachBytes(surface);
            case "attach-render" -> client.attachRender(surface);
            case "attach-browser" -> client.attachBrowser(surface);
            default -> throw new IllegalArgumentException("unknown stream " + kind);
        };
    }

    private static Object stream(Map<String, Object> request) throws Exception {
        try (CmuxClient client = client(request);
             CmuxStream<? extends ProtocolEvent> stream = openStream(client, request)) {
            int count = Math.max(Math.toIntExact(number(request, "events", 1)), 1);
            Duration timeout = Duration.ofMillis(
                Math.max(number(request, "timeout_ms", 1000), 1)
            );
            List<Object> events = new ArrayList<>();
            boolean terminal = false;
            for (int index = 0; index < count; index++) {
                try {
                    ProtocolEvent event = stream.next(timeout);
                    events.add(eventValue(event));
                    if ("overflow".equals(event.event()) || "detached".equals(event.event())) {
                        terminal = true;
                    }
                } catch (Exception error) {
                    if (terminal || stream.isClosed()) {
                        terminal = true;
                        break;
                    }
                    throw error;
                }
            }
            return Map.of("events", events, "terminal", terminal);
        }
    }

    private static Object requiredNullableEvent(Map<String, Object> request) throws Exception {
        try (CmuxClient client = client(request);
             CmuxStream<? extends ProtocolEvent> stream = openStream(client, request)) {
            Duration timeout = Duration.ofMillis(
                Math.max(number(request, "timeout_ms", 1000), 1)
            );
            ProtocolEvent event = stream.next(timeout);
            if (!(event instanceof ClientChangedEvent changed)) {
                throw new CmuxDecodeException(
                    "expected client-changed event, received " + event.event(),
                    null
                );
            }
            LinkedHashMap<String, Object> result = new LinkedHashMap<>();
            result.put("name", changed.name());
            return result;
        }
    }

    private static Object optionalNonNullEvent(Map<String, Object> request) throws Exception {
        try (CmuxClient client = client(request);
             CmuxStream<? extends ProtocolEvent> stream = openStream(client, request)) {
            Duration timeout = Duration.ofMillis(
                Math.max(number(request, "timeout_ms", 1000), 1)
            );
            ProtocolEvent event = stream.next(timeout);
            if (!(event instanceof OutputEvent output)) {
                throw new CmuxDecodeException(
                    "expected output event, received " + event.event(),
                    null
                );
            }
            return Map.of("present", output.colors().isPresent());
        }
    }

    private static Object eventValue(ProtocolEvent event) {
        if (event instanceof UnknownEvent unknown) {
            return Map.of(
                "event",
                unknown.event(),
                "unknown",
                true,
                "raw",
                normalize(unknown.raw(), null)
            );
        }
        return normalize(event.toWire(), null);
    }

    private static Object normalize(Object value, String key) {
        if (value instanceof UInt64 unsigned) {
            return unsigned.toString();
        }
        if (value instanceof Bytes bytes) {
            return bytes.toBase64();
        }
        if (value instanceof Map<?, ?> map) {
            LinkedHashMap<String, Object> result = new LinkedHashMap<>();
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                String itemKey = String.valueOf(entry.getKey());
                result.put(itemKey, normalize(entry.getValue(), itemKey));
            }
            return result;
        }
        if (value instanceof List<?> list) {
            return list.stream().map(item -> normalize(item, null)).toList();
        }
        if (value instanceof Number && isUInt64Key(key)) {
            return value.toString();
        }
        return value;
    }

    private static boolean isUInt64Key(String key) {
        if (key == null) {
            return false;
        }
        return switch (key) {
            case "client", "index", "offset", "pane", "pane_revision",
                "projection_revision", "request", "screen", "seq", "surface",
                "terminal_revision", "timeout_ms", "workspace", "workspace_revision" -> true;
            default -> key.endsWith("_revision");
        };
    }

    private static Object closePendingStream(Map<String, Object> request) throws Exception {
        try (CmuxClient client = client(request);
             CmuxStream<? extends ProtocolEvent> stream = openStream(client, request)) {
            CountDownLatch finished = new CountDownLatch(1);
            Thread reader = new Thread(() -> {
                try {
                    stream.next(Duration.ofSeconds(10));
                } catch (Throwable ignored) {
                    // Closing the stream is expected to fail the pending read.
                } finally {
                    finished.countDown();
                }
            });
            reader.setDaemon(true);
            reader.start();
            Thread.sleep(Math.max(number(request, "close_after_ms", 50), 1));
            stream.close();
            boolean unblocked = finished.await(
                Math.max(number(request, "deadline_ms", 1000), 1),
                TimeUnit.MILLISECONDS
            );
            reader.join(100);
            return Map.of("unblocked", unblocked);
        }
    }

    private static Object authority(Map<String, Object> request) throws Exception {
        String authorityName = string(request, "authority", "");
        try (CmuxClient client = client(
            request,
            authorityName.equals("provider-authority")
        )) {
            String command;
            switch (authorityName) {
                case "control" -> {
                    client.ping();
                    command = "ping";
                }
                case "frontend" -> {
                    client.browserBack(
                        com.cmux.raw.BrowserBackRequest.builder()
                            .surface(UInt64.of(7))
                            .build()
                    );
                    command = "browser-back";
                }
                case "local-admin" -> {
                    client.pairingResponse(
                        PairingResponseRequest.builder()
                            .request(UInt64.of(1))
                            .approve(false)
                            .build()
                    );
                    command = "pairing-response";
                }
                case "provider-authority" -> {
                    client.markWorkspacesProviderManaged(
                        MarkWorkspacesProviderManagedRequest.builder()
                            .authority("conformance-authority")
                            .build()
                    );
                    command = "mark-workspaces-provider-managed";
                }
                default -> throw new IllegalArgumentException(
                    "unknown authority " + request.get("authority")
                );
            }
            return Map.of("command", command);
        }
    }

    private static Object authorityDenied(Map<String, Object> request) throws Exception {
        try (CmuxClient client = client(request)) {
            try {
                client.markWorkspacesProviderManaged(
                    MarkWorkspacesProviderManagedRequest.builder()
                        .authority("conformance-authority")
                        .build()
                );
            } catch (CmuxAuthorityException expected) {
                return Map.of("denied", true);
            }
        }
        throw new IllegalStateException(
            "default client allowed provider-authority command"
        );
    }

    private record SurfaceContext(
        com.cmux.raw.Workspace workspace,
        com.cmux.raw.Tab tab
    ) {}

    private static SurfaceContext findSurface(
        com.cmux.raw.Tree tree,
        UInt64 surface
    ) {
        for (var workspace : tree.workspaces()) {
            for (var screen : workspace.screens()) {
                for (var pane : screen.panes()) {
                    if (!pane.isLivePane()) {
                        continue;
                    }
                    for (var tab : pane.livePane().tabs()) {
                        if (tab.surface().equals(surface)) {
                            return new SurfaceContext(workspace, tab);
                        }
                    }
                }
            }
        }
        return null;
    }

    private static Object realFlow(Map<String, Object> request) throws Exception {
        String marker = string(request, "marker", "cmux-sdk-conformance-marker");
        String workspaceName = string(
            request,
            "workspace_name",
            "sdk-conformance-workspace"
        );
        String renamedName = string(
            request,
            "renamed_name",
            "sdk-conformance-renamed"
        );
        try (CmuxClient client = client(request);
             CmuxStream<com.cmux.raw.DeltaStreamEvent> stream =
                 client.subscribeDeltas()) {
            var identity = client.identify();
            var created = client.newWorkspace(
                com.cmux.raw.NewWorkspaceRequest.builder()
                    .name(workspaceName)
                    .cols(80)
                    .rows(24)
                    .build()
            );
            UInt64 surface = created.surface();
            UInt64 workspace = null;
            boolean closed = false;
            try {
                client.send(
                    com.cmux.raw.SendRequest.builder()
                        .surface(surface)
                        .text("printf '" + marker + "\\n'\r")
                        .build()
                );
                var waited = client.waitFor(
                    com.cmux.raw.WaitForRequest.builder()
                        .surface(surface)
                        .pattern(marker)
                        .timeoutMs(UInt64.of(5_000))
                        .build()
                );
                var screenText = client.readScreen(
                    com.cmux.raw.ReadScreenRequest.builder()
                        .surface(surface)
                        .build()
                );
                SurfaceContext context = findSurface(client.listWorkspaces(), surface);
                if (context == null) {
                    throw new IllegalStateException(
                        "created surface " + surface + " is absent from the tree"
                    );
                }
                workspace = context.workspace().id();
                boolean terminalCreated =
                    context.tab().kind() == com.cmux.raw.TabKind.PTY
                    && !context.tab().dead();
                var renamedResult = client.renameWorkspace(
                    com.cmux.raw.RenameWorkspaceRequest.builder()
                        .workspace(workspace)
                        .name(renamedName)
                        .build()
                );
                boolean renamed = renamedResult.workspace().equals(workspace);
                client.closeWorkspace(
                    com.cmux.raw.CloseWorkspaceRequest.builder()
                        .workspace(workspace)
                        .build()
                );
                closed = true;
                UInt64 closedWorkspace = workspace;
                boolean disappeared = client.listWorkspaces().workspaces().stream()
                    .noneMatch(item -> item.id().equals(closedWorkspace));

                List<String> required = List.of(
                    "workspace-added",
                    "workspace-renamed",
                    "workspace-closed"
                );
                List<String> observed = new ArrayList<>();
                Duration timeout = Duration.ofMillis(
                    Math.max(number(request, "timeout_ms", 5_000), 1)
                );
                while (observed.size() < 64 && !observed.containsAll(required)) {
                    observed.add(stream.next(timeout).event());
                }
                int previous = -1;
                boolean streamOrdered = true;
                for (String name : required) {
                    int position = observed.indexOf(name);
                    if (position <= previous) {
                        streamOrdered = false;
                    }
                    previous = position;
                }

                LinkedHashMap<String, Object> result = new LinkedHashMap<>();
                result.put("identified", identity.protocol() == 12);
                result.put("workspace_created", workspace.compareTo(UInt64.ZERO) > 0);
                result.put("terminal_created", terminalCreated);
                result.put("marker_sent", true);
                result.put("wait_matched", waited.matched());
                result.put("read_contains_marker", screenText.text().contains(marker));
                result.put("stream_ordered", streamOrdered);
                result.put("renamed", renamed);
                result.put("closed", closed);
                result.put("disappeared", disappeared);
                result.put("observed_events", observed);
                return result;
            } finally {
                if (workspace != null && !closed) {
                    try {
                        client.closeWorkspace(
                            com.cmux.raw.CloseWorkspaceRequest.builder()
                                .workspace(workspace)
                                .build()
                        );
                    } catch (Throwable ignored) {
                        // Preserve the primary conformance failure.
                    }
                }
            }
        }
    }

    private static String classify(Throwable error) {
        String text = String.valueOf(error.getMessage()).toLowerCase();
        if (error instanceof CmuxTimeoutException || text.contains("timed out")) {
            return "timeout";
        }
        if (text.contains("exceed") || text.contains("too large") || text.contains("buffer")) {
            return "limit";
        }
        if (error instanceof CmuxCommandException) {
            return "command";
        }
        if (
            error instanceof CmuxDecodeException
                || text.contains("utf-8")
                || text.contains("json")
        ) {
            return "decode";
        }
        return "transport";
    }

    private static String string(Map<String, Object> value, String key, String fallback) {
        Object raw = value.get(key);
        return raw == null ? fallback : String.valueOf(raw);
    }

    private static long number(Map<String, Object> value, String key, long fallback) {
        Object raw = value.get(key);
        if (raw == null) {
            return fallback;
        }
        return Long.parseLong(raw.toString());
    }
}
