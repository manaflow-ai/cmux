package com.cmux.raw;

import com.cmux.raw.BrowserAttachEvent;
import com.cmux.raw.BrowserStateEvent;
import com.cmux.raw.ByteAttachEvent;
import com.cmux.raw.SubscribeEvent;
import com.cmux.raw.VtStateEvent;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

public final class StreamModeTest {
    public static void main(String[] args) throws Exception {
        Path socket = Files.createTempFile("cmux-java-modes", ".sock");
        Files.deleteIfExists(socket);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        try (ServerSocketChannel listener = ServerSocketChannel.open(StandardProtocolFamily.UNIX)) {
            listener.bind(UnixDomainSocketAddress.of(socket));
            Thread server = new Thread(() -> {
                try {
                    serve(listener);
                } catch (Throwable error) {
                    failure.set(error);
                }
            }, "cmux-java-stream-modes");
            server.start();
            try (CmuxClient client = CmuxClient.builder()
                    .socketPath(socket)
                    .timeout(Duration.ofSeconds(2))
                    .build()) {
                try (CmuxStream<SubscribeEvent> subscription = client.subscribeEvents()) {
                    check("future".equals(subscription.next().event()), "coarse subscription");
                }

                try {
                    client.attachRender(UInt64.of(1));
                    throw new AssertionError("protocol 6 accepted render mode");
                } catch (CmuxProtocolMismatchException expected) {
                    check(expected.getMessage().contains("requires protocol 7"), "render mode gate");
                }

                try (CmuxStream<ByteAttachEvent> bytes = client.attachBytes(UInt64.of(1))) {
                    check(bytes.next() instanceof VtStateEvent, "byte attach initial event");
                }
                try (CmuxStream<BrowserAttachEvent> browser = client.attachBrowser(UInt64.of(2))) {
                    check(browser.next() instanceof BrowserStateEvent, "browser attach initial event");
                }
            }
            server.join(5_000);
            check(!server.isAlive(), "stream-mode server completed");
            if (failure.get() != null) {
                throw new AssertionError("stream-mode server failed", failure.get());
            }
        } finally {
            Files.deleteIfExists(socket);
        }
    }

    private static void serve(ServerSocketChannel listener) throws Exception {
        try (SocketChannel commands = listener.accept()) {
            Map<String, Object> identify = read(commands);
            write(commands, success(identify.get("id"), Map.of(
                "protocol", 6L,
                "capabilities", List.of()
            )));

            try (SocketChannel subscription = listener.accept()) {
                Map<String, Object> request = read(subscription);
                check("subscribe".equals(request.get("cmd")), "subscribe command");
                check(!request.containsKey("tree_events"), "legacy coarse mode is omitted");
                write(subscription, success(request.get("id"), Map.of()));
                write(subscription, Map.of("event", "future"));
            }

            try (SocketChannel bytes = listener.accept()) {
                Map<String, Object> request = read(bytes);
                check("attach-surface".equals(request.get("cmd")), "byte attach command");
                check(!request.containsKey("mode"), "legacy byte mode is omitted");
                write(bytes, Map.of(
                    "event", "vt-state",
                    "surface", 1L,
                    "cols", 80L,
                    "rows", 24L,
                    "data", ""
                ));
            }

            try (SocketChannel browser = listener.accept()) {
                Map<String, Object> request = read(browser);
                check("attach-surface".equals(request.get("cmd")), "browser attach command");
                check(!request.containsKey("mode"), "browser mode is selected by surface kind");
                LinkedHashMap<String, Object> event = new LinkedHashMap<>();
                event.put("event", "browser-state");
                event.put("surface", 2L);
                event.put("cols", 100L);
                event.put("rows", 30L);
                event.put("url", "https://example.com");
                event.put("title", "Example");
                event.put("status", "live");
                event.put("error", null);
                event.put("frames_stalled", false);
                write(browser, event);
            }
        }
    }

    private static Map<String, Object> success(Object id, Object data) {
        LinkedHashMap<String, Object> result = new LinkedHashMap<>();
        result.put("id", id);
        result.put("ok", true);
        result.put("data", data);
        return result;
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> read(SocketChannel channel) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        ByteBuffer one = ByteBuffer.allocate(1);
        while (channel.read(one) >= 0) {
            one.flip();
            if (one.hasRemaining()) {
                byte value = one.get();
                if (value == '\n') {
                    return (Map<String, Object>) Json.parse(bytes.toByteArray(), 128);
                }
                bytes.write(value);
            }
            one.clear();
        }
        throw new IOException("client closed before request");
    }

    private static void write(SocketChannel channel, Map<String, Object> value) throws IOException {
        ByteBuffer bytes = ByteBuffer.wrap(
            (Json.stringify(value) + "\n").getBytes(StandardCharsets.UTF_8)
        );
        while (bytes.hasRemaining()) {
            channel.write(bytes);
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
