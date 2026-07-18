package com.cmux;

import java.util.List;
import java.util.Map;
import java.util.LinkedHashMap;
import java.nio.file.Files;
import java.nio.file.Path;

public final class JsonTest {
    @SuppressWarnings("unchecked")
    public static void main(String[] args) throws Exception {
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
        ProcessInfoResult processInfo = ProcessInfoResult.from(
            (Map<String, Object>) Json.parse(
                "{\"pid\":42,\"command\":[\"/bin/zsh\",\"-l\"],\"cwd\":\"/tmp\",\"tty\":\"/dev/ttys004\"}"
            )
        );
        assertEquals(42L, processInfo.pid(), "process pid");
        assertEquals(List.of("/bin/zsh", "-l"), processInfo.command(), "process argv");
        assertEquals("/tmp", processInfo.cwd(), "process cwd");
        assertEquals("/dev/ttys004", processInfo.tty(), "process tty");
        try {
            ProcessInfoResult.from(
                (Map<String, Object>) Json.parse(
                    "{\"pid\":42,\"command\":\"/bin/zsh -l\",\"cwd\":null,\"tty\":null}"
                )
            );
            throw new AssertionError("accepted legacy joined process command");
        } catch (IllegalArgumentException expectedError) {
            // expected
        }

        java.util.UUID workspaceUuid = java.util.UUID.fromString("cccccccc-cccc-4ccc-8ccc-cccccccccccc");
        java.util.UUID surfaceUuid = java.util.UUID.fromString("dddddddd-dddd-4ddd-8ddd-dddddddddddd");
        EnsureTerminalRequest ensureRequest = EnsureTerminalRequest.builder(workspaceUuid, surfaceUuid, 80, 24)
            .argv(List.of("/bin/zsh", "-l"))
            .environment(List.of(new EnsureTerminalEnvironment("CMUX_TEST", "1")))
            .waitAfterCommand(true)
            .build();
        assertEquals(Boolean.TRUE, ensureRequest.toMap().get("wait_after_command"), "ensure wait policy");
        EnsureTerminalResult ensured = EnsureTerminalResult.from(
            (Map<String, Object>) Json.parse(
                "{\"created\":true,\"workspace\":1,\"workspace_uuid\":\"cccccccc-cccc-4ccc-8ccc-cccccccccccc\",\"screen\":2,\"screen_uuid\":\"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee\",\"pane\":3,\"pane_uuid\":\"ffffffff-ffff-4fff-8fff-ffffffffffff\",\"surface\":4,\"surface_uuid\":\"dddddddd-dddd-4ddd-8ddd-dddddddddddd\"}"
            )
        );
        assertTrue(ensured.created(), "ensure created");
        assertEquals(surfaceUuid, ensured.surfaceUuid(), "ensure stable surface UUID");
        ReparentTerminalResult reparented = ReparentTerminalResult.from(
            (Map<String, Object>) Json.parse(
                "{\"moved\":true,\"workspace\":1,\"workspace_uuid\":\"cccccccc-cccc-4ccc-8ccc-cccccccccccc\",\"screen\":2,\"screen_uuid\":\"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee\",\"pane\":3,\"pane_uuid\":\"ffffffff-ffff-4fff-8fff-ffffffffffff\",\"surface\":4,\"surface_uuid\":\"dddddddd-dddd-4ddd-8ddd-dddddddddddd\"}"
            )
        );
        assertTrue(reparented.moved(), "reparent moved");
        assertEquals(surfaceUuid, reparented.surfaceUuid(), "reparent stable surface UUID");

        Map<String, Object> vectors = (Map<String, Object>) Json.parse(
            Files.readString(Path.of("../conformance/topology-v8.json"))
        );
        IdentifyResult identity = IdentifyResult.from((Map<String, Object>) vectors.get("identify"));
        assertEquals(47L, identity.topologyRevision(), "legacy topology revision");
        assertEquals(41L, identity.topologyCursor().orElseThrow().revision(), "canonical topology cursor");
        PingResult ping = PingResult.from((Map<String, Object>) vectors.get("ping"));
        assertTrue(ping.ok(), "ping liveness");
        assertEquals(47L, ping.topologyRevision(), "ping legacy revision");
        assertEquals(41L, ping.canonicalTopologyRevision(), "ping canonical revision");
        TopologySnapshot snapshot = TopologySnapshot.from((Map<String, Object>) vectors.get("snapshot"));
        assertEquals(41L, snapshot.revision(), "topology snapshot revision");
        assertEquals(
            4L,
            snapshot.topology().workspaces().get(0).screens().get(0).panes().get(0).tabs().get(0).id(),
            "canonical tab handle"
        );
        TopologyDelta delta = TopologyDelta.from((Map<String, Object>) vectors.get("delta"));
        assertEquals(TopologyOperation.WORKSPACE_RENAMED, delta.operation(), "topology operation");
        assertEquals(null, TopologySubscription.validate(snapshot.cursor(), delta), "adjacent delta fence");
        List<Object> recovery = (List<Object>) vectors.get("resnapshot_results");
        List<TopologyResnapshotReason> reasons = List.of(
            TopologyResnapshotReason.STALE_DAEMON,
            TopologyResnapshotReason.STALE_SESSION,
            TopologyResnapshotReason.REVISION_AHEAD,
            TopologyResnapshotReason.HISTORY_GAP,
            TopologyResnapshotReason.REPLAY_TOO_LARGE
        );
        for (int index = 0; index < reasons.size(); index++) {
            TopologyResnapshotRequired required = TopologyResnapshotRequired.from(
                (Map<String, Object>) recovery.get(index)
            );
            assertEquals(reasons.get(index), required.reason(), "resnapshot reason " + index);
        }
        TopologyResnapshotRequired slow = TopologyResnapshotRequired.from(
            (Map<String, Object>) vectors.get("slow_consumer_event")
        );
        assertEquals(TopologyResnapshotReason.SLOW_CONSUMER, slow.reason(), "slow consumer reason");
        assertEquals(null, slow.currentRevision(), "slow consumer optional revision");
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
