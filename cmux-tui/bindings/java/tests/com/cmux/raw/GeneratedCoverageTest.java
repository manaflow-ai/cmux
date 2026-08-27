package com.cmux.raw;

import com.cmux.raw.CommandMetadata;
import com.cmux.raw.Commands;
import com.cmux.raw.EventMetadata;
import com.cmux.raw.Events;
import com.cmux.raw.GeneratedCmuxClient;
import com.cmux.raw.Protocol;
import com.cmux.raw.ProtocolEvent;
import com.cmux.raw.UnknownEvent;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

public final class GeneratedCoverageTest {
    public static void main(String[] args) throws Exception {
        check(Protocol.VERSION == 12, "protocol version");
        check("1.0.0".equals(Protocol.SDK_VERSION), "SDK release version");
        check(Commands.ALL.size() == 103, "all 103 commands generated");
        check(Events.ALL.size() == 46, "all 46 events generated");

        Map<String, Method> methods = Arrays.stream(GeneratedCmuxClient.class.getDeclaredMethods())
            .filter(method -> Modifier.isPublic(method.getModifiers()))
            .collect(Collectors.toMap(Method::getName, method -> method));
        Map<String, Class<?>> layoutCommandRequests = Map.of(
            "clear-history", ClearHistoryRequest.class,
            "new-pane-right", NewPaneRightRequest.class,
            "set-viewport-pane-width", SetViewportPaneWidthRequest.class,
            "undo-layout", UndoLayoutRequest.class
        );
        for (Map.Entry<String, Class<?>> entry : layoutCommandRequests.entrySet()) {
            CommandMetadata metadata = Commands.ALL.get(entry.getKey());
            check(metadata != null, "missing generated command " + entry.getKey());
            Method method = methods.get(camel(entry.getKey()));
            check(method != null, "missing typed method " + camel(entry.getKey()));
            check(
                method.getParameterCount() == 1
                    && method.getParameterTypes()[0].equals(entry.getValue()),
                "generated request type " + entry.getKey()
            );
        }
        for (CommandMetadata command : Commands.ALL.values()) {
            String methodName = camel(command.wireName());
            Method method = methods.get(methodName);
            check(method != null, "missing typed method " + methodName);
            check(command.since() <= Protocol.VERSION, "future command version " + command.wireName());
            check(command.authority() != null, "command authority " + command.wireName());

            String requestName = "com.cmux.raw." + pascal(command.wireName()) + "Request";
            Class<?> requestClass = Class.forName(requestName);
            if (method.getParameterCount() == 1) {
                check(
                    method.getParameterTypes()[0].equals(requestClass),
                    "method request type " + command.wireName()
                );
            } else {
                check(method.getParameterCount() == 0, "canonical method arity " + command.wireName());
            }
        }
        verifyLayoutCommandRequests();
        verifyLayoutUndoVariants();
        verifyBrowserInputCommandRequests();

        for (EventMetadata event : Events.ALL.values()) {
            check(event.since() <= Protocol.VERSION, "future event version " + event.wireName());
            check(event.streams() != null, "event stream metadata " + event.wireName());
        }

        LinkedHashMap<String, Object> raw = new LinkedHashMap<>();
        raw.put("event", "future-protocol-event");
        raw.put("uint64", UInt64.MAX_VALUE.toBigInteger());
        ProtocolEvent decoded = Protocol.decodeEvent(raw);
        check(decoded instanceof UnknownEvent, "unknown event fallback");
        check(
            ((UnknownEvent) decoded).raw().get("uint64").equals(UInt64.MAX_VALUE.toBigInteger()),
            "unknown event lossless payload"
        );
    }

    private static void verifyLayoutCommandRequests() {
        check(
            ClearHistoryRequest.builder()
                .surface(UInt64.of(1))
                .build()
                .toWire()
                .keySet()
                .equals(Set.of("surface")),
            "clear-history wire fields"
        );
        check(
            NewPaneRightRequest.builder()
                .pane(UInt64.of(2))
                .build()
                .toWire()
                .keySet()
                .equals(Set.of("pane")),
            "new-pane-right wire fields"
        );
        check(
            SetViewportPaneWidthRequest.builder()
                .pane(UInt64.of(3))
                .transaction(UInt64.of(4))
                .width(0.5)
                .build()
                .toWire()
                .keySet()
                .equals(Set.of("pane", "transaction", "width")),
            "set-viewport-pane-width wire fields"
        );
        check(
            UndoLayoutRequest.builder()
                .pane(UInt64.of(5))
                .confirmClose(true)
                .revision(UInt64.of(6))
                .build()
                .toWire()
                .keySet()
                .equals(Set.of("confirm_close", "pane", "revision")),
            "undo-layout wire fields"
        );
    }

    private static void verifyLayoutUndoVariants() {
        LayoutUndoResult undone = LayoutUndoResult.fromWire(
            Map.of("undone", true, "screen", 7L, "revision", 8L)
        );
        check(undone.isLayoutUndoUndone(), "layout undo success variant");
        check(
            undone.layoutUndoUndone().screen().equals(UInt64.of(7)),
            "layout undo success screen"
        );

        LayoutUndoResult confirmation = LayoutUndoResult.fromWire(
            Map.of(
                "undone", false,
                "confirmation_required", true,
                "screen", 9L,
                "revision", 10L,
                "closes_panes", java.util.List.of(11L, 12L)
            )
        );
        check(
            confirmation.isLayoutUndoConfirmationRequired(),
            "layout undo confirmation variant"
        );
        check(
            confirmation.layoutUndoConfirmationRequired().closesPanes().equals(
                java.util.List.of(UInt64.of(11), UInt64.of(12))
            ),
            "layout undo confirmation panes"
        );
    }

    private static void verifyBrowserInputCommandRequests() {
        check(
            BrowserFramePresentedRequest.builder()
                .surface(UInt64.of(1))
                .frameSeq(UInt64.MAX_VALUE)
                .build()
                .toWire()
                .keySet()
                .equals(Set.of("surface", "frame_seq")),
            "browser-frame-presented wire fields"
        );
        check(
            BrowserMouseGuardedRequest.builder()
                .surface(UInt64.of(2))
                .frameSeq(UInt64.MAX_VALUE)
                .kind(BrowserMouseGuardedRequestKind.MOVE)
                .xPx(3.5)
                .yPx(4.5)
                .build()
                .toWire()
                .keySet()
                .equals(Set.of(
                    "surface",
                    "frame_seq",
                    "kind",
                    "x_px",
                    "y_px"
                )),
            "browser-mouse-guarded wire fields"
        );
        check(
            BrowserWheelGuardedRequest.builder()
                .surface(UInt64.of(5))
                .frameSeq(UInt64.MAX_VALUE)
                .xPx(6.5)
                .yPx(7.5)
                .deltaYPx(-8.5)
                .build()
                .toWire()
                .keySet()
                .equals(Set.of(
                    "surface",
                    "frame_seq",
                    "x_px",
                    "y_px",
                    "delta_y_px"
                )),
            "browser-wheel-guarded wire fields"
        );
        check(
            BrowserKeyPressRequest.builder()
                .surface(UInt64.of(9))
                .key("a")
                .code("KeyA")
                .windowsVirtualKeyCode(0)
                .modifiers(0)
                .build()
                .toWire()
                .keySet()
                .equals(Set.of(
                    "surface",
                    "key",
                    "code",
                    "windows_virtual_key_code",
                    "modifiers"
                )),
            "browser-key-press wire fields"
        );
        check(
            "browser-pointer-frame-guard-v1".equals(
                Commands.BROWSER_FRAME_PRESENTED.capability()
            ) &&
                "browser-pointer-frame-guard-v1".equals(
                    Commands.BROWSER_MOUSE_GUARDED.capability()
                ) &&
                "browser-pointer-frame-guard-v1".equals(
                    Commands.BROWSER_WHEEL_GUARDED.capability()
                ),
            "browser pointer guard capability metadata"
        );

        BrowserMouseRequest legacyMouse = BrowserMouseRequest.builder()
            .surface(UInt64.of(10))
            .kind(BrowserMouseRequestKind.MOVE)
            .xPx(11.5)
            .yPx(12.5)
            .frameSeq(UInt64.MAX_VALUE)
            .build();
        check(
            legacyMouse.toWire().get("frame_seq").equals(
                UInt64.MAX_VALUE.toBigInteger()
            ) && BrowserMouseRequest.fromWire(legacyMouse.toWire())
                .equals(legacyMouse),
            "legacy browser-mouse optional frame token round trip"
        );
        BrowserWheelRequest legacyWheel = BrowserWheelRequest.builder()
            .surface(UInt64.of(13))
            .xPx(14.5)
            .yPx(15.5)
            .deltaYPx(-16.5)
            .frameSeq(null)
            .build();
        check(
            legacyWheel.toWire().containsKey("frame_seq") &&
                legacyWheel.toWire().get("frame_seq") == null &&
                BrowserWheelRequest.fromWire(legacyWheel.toWire())
                    .equals(legacyWheel),
            "legacy browser-wheel explicit null frame token round trip"
        );
    }

    private static String pascal(String value) {
        StringBuilder result = new StringBuilder();
        for (String part : value.split("[^A-Za-z0-9]+")) {
            if (!part.isEmpty()) {
                result.append(Character.toUpperCase(part.charAt(0))).append(part.substring(1));
            }
        }
        return result.toString();
    }

    private static String camel(String value) {
        String pascal = pascal(value);
        return Character.toLowerCase(pascal.charAt(0)) + pascal.substring(1);
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
