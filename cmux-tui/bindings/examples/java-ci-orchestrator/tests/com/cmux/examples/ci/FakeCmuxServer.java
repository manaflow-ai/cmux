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
        TIMEOUT
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
    private final String expectedMarker;
    private final String expectedCommand;
    private final BlockingQueue<Map<String, Object>> inbound =
        new LinkedBlockingQueue<>();
    private final List<Map<String, Object>> requests = new ArrayList<>();
    private boolean closed;

    FakeCmuxServer(
        Scenario scenario,
        String expectedMarker,
        String expectedCommand
    ) {
        this.scenario = scenario;
        this.expectedMarker = expectedMarker;
        this.expectedCommand = expectedCommand;
    }

    @Override
    public synchronized void send(Map<String, Object> message) {
        if (closed) {
            throw new IllegalStateException("fake server is closed");
        }
        Map<String, Object> request = new LinkedHashMap<>(message);
        requireEquals("cmux.protocol/1", request.get("protocol"), "protocol");
        requireEquals("request", request.get("type"), "request type");
        requests.add(request);

        String operation = string(request.get("operation"), "operation");
        String id = string(request.get("id"), "request id");
        Map<String, Object> params = object(request.get("params"), "params");
        Object result = switch (operation) {
            case "workspace.create" -> createWorkspace(params);
            case "workspace.run" -> runWorkspace(params);
            case "terminal.wait" -> waitForTerminal(params);
            case "terminal.screen.read" -> readScreen(params);
            case "terminal.history.read" -> readHistory(params);
            case "notification.create" -> createNotification(params);
            case "workspace.close" -> closeWorkspace(params);
            default -> throw new AssertionError(
                "unexpected resource operation " + operation
            );
        };
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

    private Object createWorkspace(Map<String, Object> params) {
        requireCurrentRoute(params);
        requireEquals("cmux-ci-test", params.get("name"), "workspace name");
        requireEquals("empty", params.get("initial_content"), "initial content");
        return mutation(
            Map.of("kind", "workspace", "workspace_id", WORKSPACE_ID),
            "2"
        );
    }

    private Object runWorkspace(Map<String, Object> params) {
        requireCurrentRoute(params);
        requireEquals(WORKSPACE_ID, params.get("workspace"), "workspace route");
        requireEquals("ci-task", params.get("name"), "terminal name");
        List<Object> argv = array(params.get("argv"), "run argv");
        if (!argv.contains(expectedCommand)) {
            throw new AssertionError("run argv omitted command: " + argv);
        }
        if (!argv.contains(expectedMarker)) {
            throw new AssertionError("run argv omitted marker: " + argv);
        }
        return mutation(
            Map.of(
                "kind", "terminal",
                "workspace_id", WORKSPACE_ID,
                "screen_id", SCREEN_ID,
                "pane_id", PANE_ID,
                "tab_id", TAB_ID,
                "terminal_id", TERMINAL_ID
            ),
            "3"
        );
    }

    private Object waitForTerminal(Map<String, Object> params) {
        requireTerminalRoute(params);
        String pattern = string(params.get("pattern"), "wait pattern");
        if (!pattern.contains(expectedMarker)) {
            throw new AssertionError("wait pattern omitted marker: " + pattern);
        }
        if (!params.containsKey("timeout_ms")) {
            throw new AssertionError("terminal.wait omitted timeout_ms");
        }
        return switch (scenario) {
            case SUCCESS -> Map.of(
                "matched", true,
                "text", "compile ok\n" + expectedMarker + ":0"
            );
            case COMMAND_FAILURE -> Map.of(
                "matched", true,
                "text", "test failed\n" + expectedMarker + ":7"
            );
            case TIMEOUT -> Map.of(
                "matched", false,
                "text", "task still running"
            );
        };
    }

    private Object readScreen(Map<String, Object> params) {
        requireTerminalRoute(params);
        if (scenario == Scenario.TIMEOUT) {
            throw new AssertionError("timeout path must not read screen");
        }
        return Map.of(
            "text",
            scenario == Scenario.SUCCESS ? "compile ok" : "test failed"
        );
    }

    private Object readHistory(Map<String, Object> params) {
        requireTerminalRoute(params);
        requireEquals(65_535, params.get("limit"), "history limit");
        if (scenario == Scenario.TIMEOUT) {
            throw new AssertionError("timeout path must not read history");
        }
        return Map.of(
            "text",
            scenario == Scenario.SUCCESS
                ? "compile started\ncompile ok"
                : "tests started\ntest failed"
        );
    }

    private Object createNotification(Map<String, Object> params) {
        requireCurrentRoute(params);
        if (scenario == Scenario.SUCCESS) {
            throw new AssertionError("success path must not notify");
        }
        requireEquals("error", params.get("level"), "notification level");
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
            "4"
        );
    }

    private Object closeWorkspace(Map<String, Object> params) {
        requireCurrentRoute(params);
        requireEquals(WORKSPACE_ID, params.get("workspace"), "workspace close");
        return mutation(Map.of(), "5");
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
            "protocol", "cmux.protocol/1",
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

    private static List<Object> array(Object value, String label) {
        if (!(value instanceof List<?> list)) {
            throw new AssertionError(label + " is not an array: " + value);
        }
        return new ArrayList<>(list);
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
