package com.cmux.examples.ci;

import com.cmux.Transport;
import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;

final class FakeCmuxServer implements Transport {
    enum Scenario {
        SUCCESS,
        COMMAND_FAILURE,
        TIMEOUT,
        RUN_RESPONSE_LOSS
    }

    static final String HEX = "0123456789abcdef0123456789abcdef";
    static final String WORKSPACE_ID = "ws_" + HEX;
    static final String SCREEN_ID = "screen_" + HEX;
    static final String PANE_ID = "pane_" + HEX;
    static final String TAB_ID = "tab_" + HEX;
    static final String TERMINAL_ID = "term_" + HEX;
    static final String SESSION_ID = "session_" + HEX;
    static final String NOTIFICATION_ID = "notification_" + HEX;

    private final Scenario scenario;
    private final String expectedOperationKey;
    private final String expectedCommand;
    private final BlockingQueue<Map<String, Object>> inbound =
        new LinkedBlockingQueue<>();
    private final List<Map<String, Object>> requests = new ArrayList<>();
    private boolean droppedRunResponse;
    private boolean closed;

    FakeCmuxServer(
        Scenario scenario,
        String expectedOperationKey,
        String expectedCommand
    ) {
        this.scenario = scenario;
        this.expectedOperationKey = expectedOperationKey;
        this.expectedCommand = expectedCommand;
    }

    @Override
    public synchronized void send(Map<String, Object> message) {
        if (closed) {
            throw new IllegalStateException("fake server is closed");
        }
        Map<String, Object> request = new LinkedHashMap<>(message);
        requireEquals("cmux.protocol/2", request.get("protocol"), "protocol");
        requireEquals("request", request.get("type"), "request type");
        requests.add(request);

        String operation = string(request.get("operation"), "operation");
        String id = string(request.get("id"), "request id");
        Map<String, Object> params = object(request.get("params"), "params");
        Object result = switch (operation) {
            case "workspace.create" -> createWorkspace(request, params);
            case "workspace.run" -> runWorkspace(request, params);
            case "session.creation.resolve" -> resolveCreation(params);
            case "terminal.wait_exit" -> waitForExit(params);
            case "terminal.get" -> getTerminal(params);
            case "terminal.screen.read" -> readScreen(params);
            case "terminal.history.read" -> readHistory(params);
            case "notification.create" -> createNotification(params);
            case "workspace.close" -> closeWorkspace(params);
            default -> throw new AssertionError(
                "unexpected resource operation " + operation
            );
        };

        if (operation.equals("workspace.run")
                && scenario == Scenario.RUN_RESPONSE_LOSS
                && !droppedRunResponse) {
            droppedRunResponse = true;
            return;
        }
        inbound.add(response(id, result));
    }

    @Override
    public Map<String, Object> receive() throws IOException {
        try {
            Map<String, Object> value = inbound.take();
            if (closed && value.isEmpty()) {
                throw new IOException("fake server closed");
            }
            return value;
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new IOException("interrupted", error);
        }
    }

    @Override
    public synchronized void close() {
        if (!closed) {
            closed = true;
            inbound.offer(Map.of());
        }
    }

    synchronized List<String> operations() {
        return requests.stream()
            .map(request -> string(request.get("operation"), "operation"))
            .toList();
    }

    private Object createWorkspace(
        Map<String, Object> request,
        Map<String, Object> params
    ) {
        requireCurrentRoute(params);
        requireEquals("cmux-ci-test", params.get("name"), "workspace name");
        requireEquals("empty", params.get("initial_content"), "initial content");
        requireEquals(
            expectedOperationKey + "-workspace",
            params.get("correlation_key"),
            "workspace correlation"
        );
        requireEquals(
            expectedOperationKey + "-workspace-attempt-1",
            request.get("idempotency_key"),
            "workspace idempotency"
        );
        return mutation(
            Map.of("kind", "workspace", "workspace_id", WORKSPACE_ID),
            "2"
        );
    }

    private Object runWorkspace(
        Map<String, Object> request,
        Map<String, Object> params
    ) {
        requireCurrentRoute(params);
        requireEquals(WORKSPACE_ID, params.get("workspace"), "workspace route");
        requireEquals("ci-task", params.get("name"), "terminal name");
        requireEquals(expectedCommand, params.get("shell"), "run shell");
        requireEquals(
            expectedOperationKey + "-run",
            params.get("correlation_key"),
            "run correlation"
        );
        requireEquals(
            expectedOperationKey + "-run-attempt-1",
            request.get("idempotency_key"),
            "run idempotency"
        );
        return mutation(terminalPath(), "3");
    }

    private Object resolveCreation(Map<String, Object> params) {
        if (scenario != Scenario.RUN_RESPONSE_LOSS || !droppedRunResponse) {
            throw new AssertionError("unexpected creation recovery");
        }
        requireCurrentRoute(params);
        requireEquals(
            expectedOperationKey + "-run",
            params.get("correlation_key"),
            "resolved correlation"
        );
        return Map.of(
            "correlation_key", expectedOperationKey + "-run",
            "state", "created",
            "recovery", "none",
            "operation", "workspace.run",
            "idempotency_key", expectedOperationKey + "-run-attempt-1",
            "created_path", terminalPath(),
            "generation", "fake-generation",
            "revision", "3"
        );
    }

    private Object waitForExit(Map<String, Object> params) {
        requireTerminalRoute(params);
        if (!params.containsKey("timeout_ms")) {
            throw new AssertionError("terminal.wait_exit omitted timeout_ms");
        }
        if (scenario == Scenario.TIMEOUT) {
            return Map.of(
                "state", "pending",
                "terminal_id", TERMINAL_ID,
                "lifecycle", "running",
                "revision", "4"
            );
        }
        return Map.of(
            "state", "exited",
            "terminal_id", TERMINAL_ID,
            "lifecycle", "exited",
            "outcome", exitOutcome(),
            "exited_at", "1000",
            "revision", "4"
        );
    }

    private Object getTerminal(Map<String, Object> params) {
        requireTerminalRoute(params);
        if (scenario == Scenario.TIMEOUT) {
            throw new AssertionError("timeout path must not refresh terminal");
        }
        return Map.of(
            "id", TERMINAL_ID,
            "tab_id", TAB_ID,
            "tab_ids", List.of(TAB_ID),
            "title", "ci-task",
            "cols", 80,
            "rows", 24,
            "running", false,
            "lifecycle", "exited",
            "exit", Map.of(
                "outcome", exitOutcome(),
                "exited_at", "1000",
                "revision", "4"
            )
        );
    }

    private Object readScreen(Map<String, Object> params) {
        requireTerminalRoute(params);
        if (scenario == Scenario.TIMEOUT) {
            throw new AssertionError("timeout path must not read screen");
        }
        return Map.of(
            "text", outputLine(),
            "cols", 80,
            "rows", 24,
            "cursor_row", 1,
            "cursor_col", 0,
            "cursor_visible", true,
            "extra", Map.of()
        );
    }

    private Object readHistory(Map<String, Object> params) {
        requireTerminalRoute(params);
        requireEquals(65_535, params.get("limit"), "history limit");
        if (scenario == Scenario.TIMEOUT) {
            throw new AssertionError("timeout path must not read history");
        }
        String first = exitCode() == 0 ? "compile started" : "tests started";
        return mapWithNullableNext(
            "0",
            List.of(renderRow(0, first), renderRow(1, outputLine()))
        );
    }

    private Object createNotification(Map<String, Object> params) {
        requireCurrentRoute(params);
        if (scenario == Scenario.SUCCESS
                || scenario == Scenario.RUN_RESPONSE_LOSS) {
            throw new AssertionError("successful path must not notify");
        }
        requireEquals("error", params.get("level"), "notification level");
        if (scenario == Scenario.COMMAND_FAILURE) {
            requireEquals(
                TERMINAL_ID,
                params.get("terminal_id"),
                "command failure notification terminal"
            );
        } else if (params.containsKey("terminal_id")) {
            throw new AssertionError(
                "orchestration failure notification must be session-scoped"
            );
        }
        String title = string(params.get("title"), "notification title");
        String body = string(params.get("body"), "notification body");
        if (title.isBlank() || body.isBlank()) {
            throw new AssertionError("notification title and body must not be blank");
        }
        return mutation(
            Map.of(
                "id", NOTIFICATION_ID,
                "session_id", SESSION_ID,
                "title", title,
                "body", body,
                "level", "error",
                "created_at_ms", "100",
                "unread", true
            ),
            "5"
        );
    }

    private Object closeWorkspace(Map<String, Object> params) {
        requireCurrentRoute(params);
        requireEquals(WORKSPACE_ID, params.get("workspace"), "workspace close");
        return mutation(Map.of(), "6");
    }

    private Map<String, Object> terminalPath() {
        return Map.of(
            "kind", "terminal",
            "workspace_id", WORKSPACE_ID,
            "screen_id", SCREEN_ID,
            "pane_id", PANE_ID,
            "tab_id", TAB_ID,
            "terminal_id", TERMINAL_ID
        );
    }

    private Map<String, Object> exitOutcome() {
        return Map.of("kind", "exit", "code", exitCode());
    }

    private int exitCode() {
        return scenario == Scenario.COMMAND_FAILURE ? 7 : 0;
    }

    private String outputLine() {
        return exitCode() == 0 ? "compile ok" : "test failed";
    }

    private static Map<String, Object> renderRow(int row, String text) {
        return Map.of(
            "row", row,
            "runs", List.of(Map.of(
                "text", text,
                "fg", "#d0d0d0",
                "bg", "#101010",
                "attrs", 0,
                "underline", "single",
                "width_hint", text.length()
            ))
        );
    }

    private static Map<String, Object> mapWithNullableNext(
        String start,
        List<Map<String, Object>> rows
    ) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("start", start);
        result.put("next", null);
        result.put("rows", rows);
        return result;
    }

    private static void requireCurrentRoute(Map<String, Object> params) {
        requireEquals("current", params.get("machine"), "machine route");
        requireEquals("current", params.get("session"), "session route");
    }

    private static void requireTerminalRoute(Map<String, Object> params) {
        requireCurrentRoute(params);
        requireEquals(TERMINAL_ID, params.get("terminal"), "terminal route");
    }

    private static Map<String, Object> mutation(Object value, String revision) {
        return Map.of(
            "value", value,
            "generation", "fake-generation",
            "revision", revision,
            "replayed", false
        );
    }

    private static Map<String, Object> response(String id, Object result) {
        return Map.of(
            "protocol", "cmux.protocol/2",
            "type", "response",
            "id", id,
            "ok", true,
            "result", result
        );
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> object(Object value, String label) {
        if (!(value instanceof Map<?, ?>)) {
            throw new AssertionError(label + " is not an object: " + value);
        }
        return (Map<String, Object>) value;
    }

    private static String string(Object value, String label) {
        if (!(value instanceof String text)) {
            throw new AssertionError(label + " is not a string: " + value);
        }
        return text;
    }

    private static void requireEquals(Object expected, Object actual, String label) {
        if (!expected.equals(actual)) {
            throw new AssertionError(
                label + " expected " + expected + ", got " + actual
            );
        }
    }
}
