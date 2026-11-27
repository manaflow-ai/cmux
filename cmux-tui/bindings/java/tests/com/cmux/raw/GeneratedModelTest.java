package com.cmux.raw;

import com.cmux.raw.BrowserStateEvent;
import com.cmux.raw.BrowserStateEventStatus;
import com.cmux.raw.Layout;
import com.cmux.raw.LayoutLeaf;
import com.cmux.raw.LayoutSplit;
import com.cmux.raw.DeadPane;
import com.cmux.raw.OutputEvent;
import com.cmux.raw.OverflowEvent;
import com.cmux.raw.Pane;
import com.cmux.raw.Protocol;
import com.cmux.raw.SendRequest;
import com.cmux.raw.SplitDirection;
import com.cmux.raw.TerminalPlacement;
import java.math.BigInteger;
import java.util.LinkedHashMap;
import java.util.Map;

public final class GeneratedModelTest {
    public static void main(String[] args) {
        requestPresenceAndUint64RoundTrip();
        taggedUnionRoundTrip();
        untaggedUnionHasTypedVariants();
        byteEventDecodesBase64();
        requiredNullableFieldsRemainExact();
        literalPresenceRemainsExact();
        buildersRejectMissingRequiredFields();
    }

    private static void requestPresenceAndUint64RoundTrip() {
        SendRequest request = SendRequest.builder()
            .surface(UInt64.MAX_VALUE)
            .bytes(Bytes.of(new byte[] {0, 1, (byte) 255}))
            .text(null)
            .build();
        Map<String, Object> wire = request.toWire();
        check(
            wire.get("surface").equals(new BigInteger("18446744073709551615")),
            "full uint64 request wire value"
        );
        check("AAH/".equals(wire.get("bytes")), "base64 request wire value");
        check(wire.containsKey("text") && wire.get("text") == null, "explicit request null");
        check(!wire.containsKey("paste"), "omitted request field");
        check(SendRequest.fromWire(wire).equals(request), "request model round trip");
    }

    private static void taggedUnionRoundTrip() {
        Layout split = LayoutSplit.builder()
            .split(UInt64.MAX_VALUE)
            .dir(SplitDirection.RIGHT)
            .ratio(0.625)
            .a(LayoutLeaf.builder().pane(UInt64.of(1)).build())
            .b(LayoutLeaf.builder().pane(UInt64.of(2)).build())
            .build();
        Layout decoded = Layout.fromWire(split.toWire());
        check(decoded.equals(split), "tagged layout round trip");
        check(decoded instanceof LayoutSplit, "tagged layout variant");
        check(
            ((LayoutSplit) decoded).split().value().equals(UInt64.MAX_VALUE),
            "stable split id precision"
        );
    }

    private static void byteEventDecodesBase64() {
        ProtocolEventFixture output = new ProtocolEventFixture(
            "output",
            Map.of("surface", UInt64.MAX_VALUE.toBigInteger(), "data", "aGVsbG8=")
        );
        OutputEvent event = (OutputEvent) Protocol.decodeEvent(output.toWire());
        check(new String(event.data().toByteArray(), java.nio.charset.StandardCharsets.UTF_8)
            .equals("hello"), "byte event base64 decoding");
        check(event.surface().equals(UInt64.MAX_VALUE), "byte event uint64");
        check(event.toWire().equals(output.toWire()), "byte event wire round trip");
    }

    private static void untaggedUnionHasTypedVariants() {
        Pane pane = Pane.fromWire(Map.of("dead", true, "id", UInt64.MAX_VALUE.toBigInteger()));
        check(pane.isDeadPane(), "untagged pane variant");
        check(pane.deadPane().id().equals(UInt64.MAX_VALUE), "typed dead-pane accessor");
        check(
            Pane.ofDeadPane(DeadPane.builder().id(UInt64.MAX_VALUE).build()).equals(pane),
            "typed untagged-union factory"
        );
    }

    private static void requiredNullableFieldsRemainExact() {
        LinkedHashMap<String, Object> raw = new LinkedHashMap<>();
        raw.put("event", "browser-state");
        raw.put("surface", 9L);
        raw.put("status", "live");
        raw.put("url", "https://example.com");
        raw.put("title", "Example");
        raw.put("error", null);
        raw.put("cols", 120L);
        raw.put("rows", 40L);
        raw.put("frames_stalled", false);
        BrowserStateEvent event = BrowserStateEvent.fromWire(raw);
        check(event.error() == null, "required nullable result field");
        check(!event.frame().isPresent(), "optional browser frame omitted");
        check(event.status() == BrowserStateEventStatus.LIVE, "inline enum model");
        check(event.toWire().containsKey("error"), "required null is serialized");
    }

    private static void literalPresenceRemainsExact() {
        LinkedHashMap<String, Object> raw = new LinkedHashMap<>();
        raw.put("already_exited", false);
        raw.put("exit", null);
        raw.put("generation", "generation-1");
        raw.put("key", "workspace-key");
        raw.put("lifecycle", "running");
        raw.put("pane", null);
        raw.put("registry_id", "registry-1");
        raw.put("replayed", false);
        raw.put("screen", null);
        raw.put("surface", null);
        raw.put("terminal_id", "term_0123456789abcdef0123456789abcdef");
        raw.put("terminal_incarnation", null);
        raw.put("terminal_revision", 4L);
        raw.put("workspace", null);

        TerminalPlacement placement = TerminalPlacement.fromWire(raw);
        check(placement.lifecycle() == TerminalLifecycle.RUNNING, "terminal lifecycle decodes");
        check(placement.surface() == null, "nullable early-exit placement decodes null");
        check(
            placement.toWire().containsKey("exit") && placement.toWire().get("exit") == null,
            "required nullable exit serializes null"
        );
        check(
            TerminalPlacement.fromWire(placement.toWire()).equals(placement),
            "terminal placement lifecycle round trip"
        );

        OverflowEvent overflow = OverflowEvent.fromWire(
            Map.of("event", "overflow", "error", "test")
        );
        check(!overflow.scope().isPresent(), "optional literal remains omitted");
        check(!overflow.toWire().containsKey("scope"), "omitted literal is not serialized");
    }

    private static void buildersRejectMissingRequiredFields() {
        try {
            SendRequest.builder().build();
            throw new AssertionError("request builder accepted missing surface");
        } catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains("surface"), "missing-field message");
        }
    }

    private record ProtocolEventFixture(String event, Map<String, Object> fields) {
        Map<String, Object> toWire() {
            LinkedHashMap<String, Object> value = new LinkedHashMap<>();
            value.put("event", event);
            value.putAll(fields);
            return value;
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
