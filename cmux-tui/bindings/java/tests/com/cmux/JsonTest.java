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
        CmuxEvent layoutEvent = CmuxEvent.from(
            (Map<String, Object>) Json.parse("{\"event\":\"layout-changed\",\"screen\":7}")
        );
        assertTrue(layoutEvent instanceof LayoutChangedEvent, "layout event type");
        assertEquals(7L, ((LayoutChangedEvent) layoutEvent).screen(), "layout event screen");
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
        Tree legacyTree = Tree.from(Map.of("workspaces", List.of()));
        assertEquals(0L, legacyTree.workspaceRevision(), "legacy workspace revision");
        assertEquals(null, legacyTree.paneRevision(), "legacy pane revision");
        Tree revisionedTree = Tree.from(Map.of("pane_revision", 7L, "workspaces", List.of()));
        assertEquals(7L, revisionedTree.paneRevision(), "pane revision");
        Tree sourceCompatibleTree = new Tree(4, List.of());
        assertEquals(null, sourceCompatibleTree.paneRevision(), "source-compatible tree pane revision");
        Pane sourceCompatiblePane = new Pane(7, "shell", 0, List.of(), false);
        assertEquals(0L, sourceCompatiblePane.focusedAt(), "source-compatible pane focus recency");

        CreateTerminalRequest terminalRequest = CreateTerminalRequest.builder()
            .key("stable")
            .command("echo ready")
            .cwd("/tmp")
            .name("runner")
            .cols(80)
            .rows(24)
            .build();
        assertEquals("stable", terminalRequest.toMap().get("key"), "terminal builder key");
        assertEquals("runner", terminalRequest.toMap().get("name"), "terminal builder name");
        try {
            WorkspaceSelectorRequest.builder().build();
            throw new AssertionError("accepted missing workspace selector");
        } catch (IllegalArgumentException expectedError) {
            assertEquals("workspace or key is required", expectedError.getMessage(), "selector validation");
        }
        IdentifyResult identify = IdentifyResult.from((Map<String, Object>) Json.parse(
            "{\"app\":\"cmux-tui\",\"version\":\"0.1.2\",\"build_commit\":\"cmux-sha\",\"ghostty_commit\":\"ghostty-sha\",\"protocol\":7,\"session\":\"main\",\"pid\":42}"
        ));
        assertEquals("cmux-sha", identify.buildCommit(), "identify build commit");
        assertEquals("ghostty-sha", identify.ghosttyCommit(), "identify Ghostty commit");
        IdentifyResult legacyIdentify = IdentifyResult.from((Map<String, Object>) Json.parse(
            "{\"app\":\"cmux-tui\",\"version\":\"0.1.2\",\"protocol\":7,\"session\":\"main\",\"pid\":42}"
        ));
        assertEquals(null, legacyIdentify.buildCommit(), "legacy identify build commit");
        assertEquals(null, legacyIdentify.ghosttyCommit(), "legacy identify Ghostty commit");
        IdentifyResult sourceCompatible = new IdentifyResult("cmux-tui", "0.1.2", 7, "main", 42);
        assertEquals(null, sourceCompatible.buildCommit(), "source-compatible build commit");
        assertEquals(null, sourceCompatible.ghosttyCommit(), "source-compatible Ghostty commit");
        IdentifyResult stampedSourceCompatible = new IdentifyResult(
            "cmux-tui", "0.1.2", 7, "main", 42, "cmux-sha", "ghostty-sha"
        );
        assertEquals(List.of(), stampedSourceCompatible.capabilities(), "source-compatible capabilities");
        assertEquals("cmux-sha", stampedSourceCompatible.buildCommit(), "source-compatible stamped build commit");
        assertEquals("ghostty-sha", stampedSourceCompatible.ghosttyCommit(), "source-compatible stamped Ghostty commit");
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
