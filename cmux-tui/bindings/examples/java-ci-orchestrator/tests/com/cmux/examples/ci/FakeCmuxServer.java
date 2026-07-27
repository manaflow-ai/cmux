package com.cmux.examples.ci;

import com.cmux.Json;
import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.channels.Channels;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

final class FakeCmuxServer implements AutoCloseable {
    enum Scenario {
        SUCCESS,
        COMMAND_FAILURE,
        TIMEOUT
    }

    private static final AtomicInteger NEXT_SOCKET = new AtomicInteger();

    private final Scenario scenario;
    private final String expectedMarker;
    private final String expectedWorkspaceKey;
    private final String expectedCommand;
    private final Path socketPath;
    private final ServerSocketChannel server;
    private final Thread thread;
    private final List<String> commands = new ArrayList<>();
    private final AtomicReference<Throwable> failure = new AtomicReference<>();
    private int readScreenCount;

    FakeCmuxServer(
        Scenario scenario,
        String expectedMarker,
        String expectedWorkspaceKey,
        String expectedCommand
    ) throws IOException {
        this.scenario = scenario;
        this.expectedMarker = expectedMarker;
        this.expectedWorkspaceKey = expectedWorkspaceKey;
        this.expectedCommand = expectedCommand;
        this.socketPath = Path.of(
            "/tmp",
            "cmux-java-ci-" + ProcessHandle.current().pid()
                + "-" + NEXT_SOCKET.incrementAndGet() + ".sock"
        );
        Files.deleteIfExists(socketPath);
        this.server = ServerSocketChannel.open(StandardProtocolFamily.UNIX);
        server.bind(UnixDomainSocketAddress.of(socketPath));
        this.thread = new Thread(this::serve, "fake-cmux-java-ci");
        thread.start();
    }

    Path socketPath() {
        return socketPath;
    }

    List<String> commands() {
        synchronized (commands) {
            return List.copyOf(commands);
        }
    }

    int readScreenCount() {
        return readScreenCount;
    }

    void await() throws Exception {
        thread.join(5_000);
        if (thread.isAlive()) {
            throw new AssertionError("fake cmux server did not stop");
        }
        Throwable serverFailure = failure.get();
        if (serverFailure != null) {
            if (serverFailure instanceof Exception exception) {
                throw exception;
            }
            throw new AssertionError("fake cmux server failed", serverFailure);
        }
    }

    private void serve() {
        try (
            SocketChannel client = server.accept();
            BufferedReader input = new BufferedReader(
                Channels.newReader(client, StandardCharsets.UTF_8)
            );
            BufferedWriter output = new BufferedWriter(
                Channels.newWriter(client, StandardCharsets.UTF_8)
            )
        ) {
            String line;
            while ((line = input.readLine()) != null) {
                Map<String, Object> request = object(Json.parse(line));
                String command = string(request.get("cmd"), "cmd");
                synchronized (commands) {
                    commands.add(command);
                }
                Object data = handle(command, request);
                writeResponse(output, request.get("id"), data);
                if ("close-workspace".equals(command)) {
                    break;
                }
            }
        } catch (Throwable error) {
            failure.set(error);
        }
    }

    private Object handle(String command, Map<String, Object> request) {
        return switch (command) {
            case "identify" -> identify();
            case "create-workspace" -> createWorkspace(request);
            case "create-terminal" -> createTerminal(request);
            case "read-screen" -> readScreen(request);
            case "read-scrollback" -> readScrollback(request);
            case "notify" -> notify(request);
            case "close-workspace" -> closeWorkspace(request);
            default -> throw new AssertionError("unexpected command " + command);
        };
    }

    private Map<String, Object> identify() {
        LinkedHashMap<String, Object> data = new LinkedHashMap<>();
        data.put("app", "cmux-tui");
        data.put("version", "0.9.0-test");
        data.put("protocol", 10);
        data.put("capabilities", List.of("workspace-registry-v1"));
        data.put("session", "fake-ci");
        data.put("pid", 4242);
        data.put("registry_id", "registry-test");
        data.put("generation", "generation-test");
        data.put("workspace_revision", 10);
        data.put("terminal_revision", 20);
        data.put("daemon_handoff", 1);
        return data;
    }

    private Map<String, Object> createWorkspace(Map<String, Object> request) {
        requireEquals(expectedWorkspaceKey, request.get("key"), "create-workspace key");
        requireEquals("cmux-ci-test", request.get("name"), "create-workspace name");
        return workspaceMutation(11, true);
    }

    private Map<String, Object> createTerminal(Map<String, Object> request) {
        requireEquals(expectedWorkspaceKey, request.get("key"), "create-terminal key");
        List<Object> argv = array(request.get("argv"), "create-terminal argv");
        if (!argv.contains(expectedCommand)) {
            throw new AssertionError("create-terminal argv omitted command: " + argv);
        }
        if (!argv.contains(expectedMarker)) {
            throw new AssertionError("create-terminal argv omitted marker: " + argv);
        }
        if (request.containsKey("terminal_id")) {
            throw new AssertionError("create-terminal unexpectedly reserved terminal_id");
        }
        requireEquals("ci-task", request.get("name"), "create-terminal name");

        LinkedHashMap<String, Object> data = new LinkedHashMap<>();
        data.put("surface", 31);
        data.put("terminal_id", null);
        data.put("terminal_incarnation", null);
        data.put("pane", 21);
        data.put("screen", 22);
        data.put("workspace", 11);
        data.put("key", expectedWorkspaceKey);
        data.put("lifecycle", null);
        data.put("terminal_revision", 21);
        data.put("replayed", false);
        data.put("registry_id", "registry-test");
        data.put("generation", "generation-test");
        return data;
    }

    private Map<String, Object> readScreen(Map<String, Object> request) {
        requireNumber(31, request.get("surface"), "read-screen surface");
        readScreenCount++;
        String text = switch (scenario) {
            case SUCCESS -> "compile ok\n" + expectedMarker + ":0";
            case COMMAND_FAILURE -> "test failed\n" + expectedMarker + ":7";
            case TIMEOUT -> "task still running";
        };
        return Map.of("text", text);
    }

    private Map<String, Object> readScrollback(Map<String, Object> request) {
        if (scenario == Scenario.TIMEOUT) {
            throw new AssertionError("timeout path must not read scrollback");
        }
        requireNumber(31, request.get("surface"), "read-scrollback surface");
        requireNumber(0, request.get("start"), "read-scrollback start");
        requireNumber(65_535, request.get("count"), "read-scrollback count");
        Map<String, Object> run = new LinkedHashMap<>();
        run.put("text", scenario == Scenario.SUCCESS ? "compile started" : "tests started");
        run.put("fg", null);
        run.put("bg", null);
        run.put("attrs", 0);
        Map<String, Object> row = Map.of("row", 0, "runs", List.of(run));
        return Map.of("rows", List.of(row), "start", 0, "total", 1);
    }

    private Map<String, Object> notify(Map<String, Object> request) {
        if (scenario == Scenario.SUCCESS) {
            throw new AssertionError("success path must not notify");
        }
        requireEquals("error", request.get("level"), "notification level");
        requireNumber(31, request.get("surface"), "notification surface");
        if (string(request.get("title"), "notification title").isBlank()) {
            throw new AssertionError("notification title must not be blank");
        }
        return Map.of("notification", 44);
    }

    private Map<String, Object> closeWorkspace(Map<String, Object> request) {
        requireEquals(expectedWorkspaceKey, request.get("key"), "close-workspace key");
        return workspaceMutation(11, true);
    }

    private Map<String, Object> workspaceMutation(int workspace, boolean changed) {
        LinkedHashMap<String, Object> data = new LinkedHashMap<>();
        data.put("workspace", workspace);
        data.put("key", expectedWorkspaceKey);
        data.put("index", 0);
        data.put("workspace_revision", 11);
        data.put("changed", changed);
        data.put("replayed", false);
        data.put("registry_id", "registry-test");
        data.put("generation", "generation-test");
        return data;
    }

    private static void writeResponse(
        BufferedWriter output,
        Object id,
        Object data
    ) throws IOException {
        LinkedHashMap<String, Object> response = new LinkedHashMap<>();
        response.put("id", id);
        response.put("ok", true);
        response.put("data", data);
        output.write(Json.stringify(response));
        output.newLine();
        output.flush();
    }

    private static Map<String, Object> object(Object value) {
        if (!(value instanceof Map<?, ?> raw)) {
            throw new AssertionError("expected JSON object, got " + value);
        }
        LinkedHashMap<String, Object> result = new LinkedHashMap<>();
        for (Map.Entry<?, ?> entry : raw.entrySet()) {
            if (!(entry.getKey() instanceof String key)) {
                throw new AssertionError("JSON object key is not a string");
            }
            result.put(key, entry.getValue());
        }
        return result;
    }

    private static List<Object> array(Object value, String label) {
        if (!(value instanceof List<?> raw)) {
            throw new AssertionError(label + " is not an array: " + value);
        }
        return new ArrayList<>(raw);
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

    private static void requireNumber(long expected, Object actual, String label) {
        if (!(actual instanceof Number number) || number.longValue() != expected) {
            throw new AssertionError(
                label + " expected " + expected + ", got " + actual
            );
        }
    }

    @Override
    public void close() throws IOException {
        server.close();
        Files.deleteIfExists(socketPath);
    }
}
