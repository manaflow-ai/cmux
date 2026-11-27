package com.cmux;

import java.io.IOException;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;

public final class BrowserPointerFrameTest {
    private static final String HEX =
        "0123456789abcdef0123456789abcdef";

    private BrowserPointerFrameTest() {}

    public static void main(String[] args) {
        frameTokenIsRequiredNullableAndExact();
        pointerInputsRequireAndEncodeExactToken();
    }

    private static void frameTokenIsRequiredNullableAndExact() {
        BrowserAttachmentItem.Frame maximum = decodeFrame(
            true,
            Decimal.MAX_VALUE.toWire()
        );
        require(
            maximum.pointerFrameSeq().equals(
                Optional.of(Decimal.MAX_VALUE)
            ),
            "frame preserves the full uint64 pointer token"
        );

        BrowserAttachmentItem.Frame blocked = decodeFrame(true, null);
        require(
            blocked.pointerFrameSeq().isEmpty(),
            "null pointer token is exposed as Optional.empty"
        );

        expect(
            ProtocolError.class,
            () -> decodeFrame(false, null)
        );
        expect(
            ProtocolError.class,
            () -> decodeFrame(true, 7L)
        );
        expect(
            ProtocolError.class,
            () -> decodeFrame(true, "01")
        );
        expect(
            ProtocolError.class,
            () -> decodeFrame(true, "18446744073709551616")
        );
    }

    private static void pointerInputsRequireAndEncodeExactToken() {
        expect(
            NullPointerException.class,
            () -> new Options.BrowserMouse(
                Options.Mutation.defaults(),
                Map.of("kind", "move", "x_px", 1.5, "y_px", 2.5),
                null
            )
        );
        expect(
            NullPointerException.class,
            () -> new Options.Wheel(
                Options.Mutation.defaults(),
                0.0,
                -3.0,
                1.5,
                2.5,
                null
            )
        );

        FrameTransport transport = new FrameTransport(true, null);
        try (Client client = client(transport)) {
            Browser browser = browser(client);

            browser.mouse(new Options.BrowserMouse(
                Options.Mutation.defaults(),
                Map.of(
                    "kind", "move",
                    "x_px", 1.5,
                    "y_px", 2.5,
                    "pointer_frame_seq", "stale"
                ),
                Decimal.MAX_VALUE
            ));
            Map<String, Object> mouse = transport.lastParams(
                "browser.input.mouse"
            );
            require(
                Decimal.MAX_VALUE.toWire().equals(
                    mouse.get("pointer_frame_seq")
                ),
                "mouse encodes the exact token as a decimal string"
            );

            browser.wheel(new Options.Wheel(
                Options.Mutation.defaults(),
                0.25,
                -3.0,
                1.5,
                2.5,
                Decimal.MAX_VALUE
            ));
            Map<String, Object> wheel = transport.lastParams(
                "browser.input.wheel"
            );
            require(
                Decimal.MAX_VALUE.toWire().equals(
                    wheel.get("pointer_frame_seq")
                ),
                "wheel encodes the exact token as a decimal string"
            );
            require(
                wheel.get("x_px").equals(1.5) &&
                    wheel.get("y_px").equals(2.5),
                "wheel always encodes pointer coordinates"
            );
        }
    }

    private static BrowserAttachmentItem.Frame decodeFrame(
        boolean includePointerFrameSeq,
        Object pointerFrameSeq
    ) {
        FrameTransport transport = new FrameTransport(
            includePointerFrameSeq,
            pointerFrameSeq
        );
        try (Client client = client(transport);
             ResourceStream<BrowserAttachmentItem> stream = browser(client)
                 .attach(new Options.BrowserAttach(
                     Options.Stream.defaults(),
                     Optional.empty(),
                     Optional.empty()
                 ))) {
            BrowserAttachmentItem item = stream
                .next(Duration.ofSeconds(1))
                .value();
            if (item instanceof BrowserAttachmentItem.Frame frame) {
                return frame;
            }
            throw new AssertionError("expected browser frame item");
        }
    }

    private static Browser browser(Client client) {
        return client.machine(Selector.current())
            .session(Selector.current())
            .browser(Selector.id(new Ids.BrowserId("browser_" + HEX)));
    }

    private static Client client(FrameTransport transport) {
        return Client.builder()
            .transport(transport)
            .timeout(Duration.ofSeconds(1))
            .idempotencyKeySource(() -> "pointer-frame-test")
            .streamIdSource(() -> "stream_" + HEX)
            .build();
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    private static <T extends Throwable> T expect(
        Class<T> type,
        ThrowingRunnable action
    ) {
        try {
            action.run();
        } catch (Throwable error) {
            if (type.isInstance(error)) {
                return type.cast(error);
            }
            throw new AssertionError(
                "expected " + type.getName() + ", got " + error,
                error
            );
        }
        throw new AssertionError("expected " + type.getName());
    }

    @FunctionalInterface
    private interface ThrowingRunnable {
        void run() throws Exception;
    }

    private static final class FrameTransport implements Transport {
        private final BlockingQueue<Map<String, Object>> inbound =
            new LinkedBlockingQueue<>();
        private final List<Map<String, Object>> sent = new ArrayList<>();
        private final boolean includePointerFrameSeq;
        private final Object pointerFrameSeq;
        private boolean closed;

        private FrameTransport(
            boolean includePointerFrameSeq,
            Object pointerFrameSeq
        ) {
            this.includePointerFrameSeq = includePointerFrameSeq;
            this.pointerFrameSeq = pointerFrameSeq;
        }

        @Override
        public synchronized void send(Map<String, Object> message) {
            Map<String, Object> request = new LinkedHashMap<>(message);
            sent.add(request);
            String operation = String.valueOf(request.get("operation"));
            String id = String.valueOf(request.get("id"));
            Map<String, Object> params = object(request.get("params"));

            if (operation.equals("browser.attach")) {
                String streamId = String.valueOf(params.get("stream_id"));
                inbound.add(response(
                    id,
                    Map.of(
                        "stream_id", streamId,
                        "attachment_lease", "browser-lease"
                    )
                ));
                inbound.add(frameItem(streamId));
                return;
            }
            if (operation.equals("stream.cancel")) {
                inbound.add(Map.of(
                    "protocol", "cmux.protocol/2",
                    "type", "stream_end",
                    "stream_id", String.valueOf(params.get("stream")),
                    "reason", "canceled"
                ));
                inbound.add(response(id, Map.of()));
                return;
            }
            if (operation.equals("browser.input.mouse") ||
                    operation.equals("browser.input.wheel")) {
                inbound.add(response(id, mutationResult()));
                return;
            }
            throw new AssertionError("unexpected operation " + operation);
        }

        @Override
        public Map<String, Object> receive() throws IOException {
            try {
                Map<String, Object> message = inbound.take();
                if (closed && message.isEmpty()) {
                    throw new IOException("closed");
                }
                return message;
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new IOException("interrupted", error);
            }
        }

        @Override
        public synchronized void close() {
            closed = true;
            inbound.offer(Map.of());
        }

        private synchronized Map<String, Object> lastParams(
            String operation
        ) {
            for (int index = sent.size() - 1; index >= 0; index--) {
                Map<String, Object> request = sent.get(index);
                if (operation.equals(request.get("operation"))) {
                    return object(request.get("params"));
                }
            }
            throw new AssertionError("operation was not sent: " + operation);
        }

        private Map<String, Object> frameItem(String streamId) {
            Map<String, Object> frame = new LinkedHashMap<>();
            frame.put("kind", "frame");
            frame.put("mime_type", "image/png");
            frame.put("data_base64", "AA==");
            frame.put("width_px", 2);
            frame.put("height_px", 1);
            if (includePointerFrameSeq) {
                frame.put("pointer_frame_seq", pointerFrameSeq);
            }
            return Map.of(
                "protocol", "cmux.protocol/2",
                "type", "stream_item",
                "stream_id", streamId,
                "sequence", "1",
                "item", frame
            );
        }

        private static Map<String, Object> mutationResult() {
            return Map.of(
                "value", Map.of(),
                "generation", "generation-1",
                "revision", "1",
                "replayed", false
            );
        }

        private static Map<String, Object> response(
            String id,
            Map<String, Object> result
        ) {
            return Map.of(
                "protocol", "cmux.protocol/2",
                "type", "response",
                "id", id,
                "ok", true,
                "result", result
            );
        }

        @SuppressWarnings("unchecked")
        private static Map<String, Object> object(Object value) {
            return (Map<String, Object>) value;
        }
    }
}
