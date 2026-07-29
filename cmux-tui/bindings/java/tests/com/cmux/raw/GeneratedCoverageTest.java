package com.cmux;

import com.cmux.generated.CommandMetadata;
import com.cmux.generated.Commands;
import com.cmux.generated.EventMetadata;
import com.cmux.generated.Events;
import com.cmux.generated.GeneratedCmuxClient;
import com.cmux.generated.Protocol;
import com.cmux.generated.ProtocolEvent;
import com.cmux.generated.UnknownEvent;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

public final class GeneratedCoverageTest {
    public static void main(String[] args) throws Exception {
        check(Protocol.VERSION == 10, "protocol version");
        check("0.4.0".equals(Protocol.SDK_VERSION), "SDK release version");
        check(Commands.ALL.size() == 83, "all 83 commands generated");
        check(Events.ALL.size() == 44, "all 44 events generated");

        Map<String, Method> methods = Arrays.stream(GeneratedCmuxClient.class.getDeclaredMethods())
            .filter(method -> Modifier.isPublic(method.getModifiers()))
            .collect(Collectors.toMap(Method::getName, method -> method));
        for (CommandMetadata command : Commands.ALL.values()) {
            String methodName = camel(command.wireName());
            Method method = methods.get(methodName);
            check(method != null, "missing typed method " + methodName);
            check(command.since() <= Protocol.VERSION, "future command version " + command.wireName());
            check(command.authority() != null, "command authority " + command.wireName());

            String requestName = "com.cmux.generated." + pascal(command.wireName()) + "Request";
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
