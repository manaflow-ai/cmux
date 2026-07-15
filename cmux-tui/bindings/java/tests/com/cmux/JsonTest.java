package com.cmux;

import java.util.List;
import java.util.Map;
import java.util.LinkedHashMap;

public final class JsonTest {
    @SuppressWarnings("unchecked")
    public static void main(String[] args) {
        Object parsed = Json.parse("{\"s\":\"a\\n\\t\\\\\\\"\",\"u\":\"\\uD83D\\uDE00\",\"n\":-12.5e2,\"a\":[true,false,null,{\"x\":1}]}");
        Map<String, Object> object = (Map<String, Object>) parsed;
        assertEquals("a\n\t\\\"", object.get("s"), "string escapes");
        assertEquals("😀", object.get("u"), "surrogate pair");
        assertEquals(-1250.0, object.get("n"), "number");
        List<Object> array = (List<Object>) object.get("a");
        assertEquals(Boolean.TRUE, array.get(0), "array true");
        assertEquals(Boolean.FALSE, array.get(1), "array false");
        assertEquals(null, array.get(2), "array null");
        assertEquals(1L, ((Map<String, Object>) array.get(3)).get("x"), "nested object");

        Map<String, Object> expected = new LinkedHashMap<>();
        expected.put("a", List.of(1L, "two"));
        expected.put("b", "line\n");
        String encoded = Json.stringify(expected);
        Object roundTrip = Json.parse(encoded);
        assertEquals(expected, roundTrip, "round trip equality");
        assertReject("[1,]");
        assertReject("{\"x\":}");
        assertReject("\"\\uD800\"");
        assertReject("01");
        assertReject("١");
        assertReject("\"\\u１２３4\"");
        assertStringifyReject(Double.NaN);
        assertStringifyReject(Double.POSITIVE_INFINITY);

        CmuxEvent event = CmuxEvent.from((Map<String, Object>) Json.parse(
            "{\"event\":\"title-changed\",\"surface\":7,\"title\":\"build logs\"}"
        ));
        assertTrue(event instanceof TitleChangedEvent, "title event type");
        TitleChangedEvent title = (TitleChangedEvent) event;
        assertEquals(7L, title.surface(), "title event surface");
        assertEquals("build logs", title.title(), "title event title");
        TitleChangedEvent legacyTitle = (TitleChangedEvent) CmuxEvent.from(
            (Map<String, Object>) Json.parse("{\"event\":\"title-changed\",\"surface\":7}")
        );
        assertEquals(null, legacyTitle.title(), "legacy title event title");
        ResizedEvent legacyResize = (ResizedEvent) CmuxEvent.from(
            (Map<String, Object>) Json.parse(
                "{\"event\":\"resized\",\"surface\":7,\"cols\":80,\"rows\":24,\"data\":\"cmVwbGF5\"}"
            )
        );
        assertEquals("cmVwbGF5", legacyResize.replay(), "protocol v6 resize replay");
        OverflowEvent overflow = (OverflowEvent) CmuxEvent.from(
            (Map<String, Object>) Json.parse(
                "{\"event\":\"overflow\",\"error\":\"subscriber fell behind\",\"scope\":\"surface\",\"surface\":7}"
            )
        );
        assertEquals("subscriber fell behind", overflow.error(), "overflow error");
        assertEquals("surface", overflow.scope(), "overflow scope");
        assertEquals(7L, overflow.surface(), "overflow surface");
        SurfaceResizeFailedEvent resizeFailed = (SurfaceResizeFailedEvent) CmuxEvent.from(
            (Map<String, Object>) Json.parse(
                "{\"event\":\"surface-resize-failed\",\"surface\":7,\"cols\":120,\"rows\":40,\"error\":\"browser is not responding\",\"retry_after_ms\":250}"
            )
        );
        assertEquals("browser is not responding", resizeFailed.error(), "resize failure error");
        assertEquals(250L, resizeFailed.retryAfterMs(), "resize failure retry schedule");
        ResizeSurfaceResult reserved = ResizeSurfaceResult.from(Map.of("accepted", true, "reservation_id", 41));
        assertEquals(41L, reserved.reservationId(), "resize reservation identity");
        assertTrue(ResizeSurfaceResult.from(Map.of()).accepted(), "legacy resize accepted");
    }

    private static void assertReject(String input) {
        try {
            Json.parse(input);
            throw new AssertionError("accepted malformed input: " + input);
        } catch (JsonException expected) {
            // expected
        }
    }

    private static void assertTrue(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    private static void assertEquals(Object expected, Object actual, String message) {
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError(message + " expected=" + expected + " actual=" + actual);
        }
    }

    private static void assertStringifyReject(Object value) {
        try {
            Json.stringify(value);
            throw new AssertionError("stringified malformed value: " + value);
        } catch (JsonException expected) {
            // expected
        }
    }
}
