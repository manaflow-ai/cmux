package com.cmux.internal;

import com.cmux.Command;
import com.cmux.Decimal;
import com.cmux.Ids;
import com.cmux.Secret;
import com.cmux.Selector;
import com.cmux.raw.Json;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Centralized protocol fields and dependency-free value conversion. */
public final class Wire {
    public static final String PROTOCOL = "cmux.protocol/2";
    public static final String SELECTOR = "selector";
    public static final String MACHINE = "machine";
    public static final String SESSION = "session";
    public static final String WORKSPACE = "workspace";
    public static final String SCREEN = "screen";
    public static final String PANE = "pane";
    public static final String TAB = "tab";
    public static final String TERMINAL = "terminal";
    public static final String BROWSER = "browser";
    public static final String CLIENT = "client";
    public static final String STREAM_ID = "stream_id";
    public static final String ATTACHMENT_LEASE = "attachment_lease";
    public static final String IDEMPOTENCY_KEY = "idempotency_key";
    public static final String ARGV = "argv";
    public static final String SHELL = "shell";
    public static final String NAME = "name";
    public static final String KIND = "kind";
    public static final String FORCE = "force";
    public static final String CONNECTION = "connection";
    public static final String INITIAL_CONTENT = "initial_content";
    public static final String CWD = "cwd";
    public static final String ENV = "env";
    public static final String LAYOUT = "layout";
    public static final String DIRECTION = "direction";
    public static final String RATIO = "ratio";
    public static final String VIEWPORT_WIDTH = "viewport_width";
    public static final String WIDTH = "width";
    public static final String HEIGHT = "height";
    public static final String COLS = "cols";
    public static final String ROWS = "rows";
    public static final String ENABLED = "enabled";
    public static final String DATA = "data";
    public static final String KEYS = "keys";
    public static final String MOUSE = "mouse";
    public static final String FOCUSED = "focused";
    public static final String START = "start";
    public static final String COUNT = "count";
    public static final String MODE = "mode";
    public static final String TEXT = "text";
    public static final String URL = "url";
    public static final String DELTA = "delta";
    public static final String GENERATION = "generation";
    public static final String REVISION = "revision";
    public static final String CURSOR = "cursor";
    public static final String TIMEOUT_MS = "timeout_ms";
    public static final String TITLE = "title";
    public static final String LABEL = "label";
    public static final String BODY = "body";
    public static final String LEVEL = "level";
    public static final String STATE = "state";
    public static final String DETAILS = "details";
    public static final String ACCEPT = "accept";
    public static final String VALUE = "value";
    public static final String INPUT = "input";
    public static final String SCOPE = "scope";
    public static final String METADATA = "metadata";
    public static final String POINTER_FRAME_SEQ = "pointer_frame_seq";

    private Wire() {}

    public static Map<String, Object> map() {
        return new LinkedHashMap<>();
    }

    public static Map<String, Object> map(String key, Object value) {
        Map<String, Object> result = map();
        result.put(key, value);
        return result;
    }

    @SuppressWarnings("unchecked")
    public static Map<String, Object> object(Object value, String context) {
        if (!(value instanceof Map<?, ?> raw)) {
            throw new IllegalArgumentException(context + " must be an object");
        }
        for (Object key : raw.keySet()) {
            if (!(key instanceof String)) {
                throw new IllegalArgumentException(context + " keys must be strings");
            }
        }
        return (Map<String, Object>) raw;
    }

    public static List<Object> array(Object value, String context) {
        if (!(value instanceof List<?> list)) {
            throw new IllegalArgumentException(context + " must be an array");
        }
        return List.copyOf(list);
    }

    public static String string(Object value, String context) {
        if (value instanceof String text) {
            return text;
        }
        throw new IllegalArgumentException(context + " must be a string");
    }

    public static boolean bool(Object value, String context) {
        if (value instanceof Boolean flag) {
            return flag;
        }
        throw new IllegalArgumentException(context + " must be a boolean");
    }

    public static Decimal decimal(Object value, String context) {
        if (value instanceof String text) {
            try {
                return Decimal.parse(text);
            } catch (IllegalArgumentException error) {
                throw new IllegalArgumentException("invalid " + context, error);
            }
        }
        throw new IllegalArgumentException(context + " must be a decimal string");
    }

    public static Object encode(Object value) {
        if (value == null || value instanceof String || value instanceof Boolean ||
                value instanceof Byte || value instanceof Short || value instanceof Integer ||
                value instanceof Long || value instanceof BigInteger ||
                value instanceof Float || value instanceof Double) {
            return value;
        }
        if (value instanceof Decimal decimal) {
            return decimal.toWire();
        }
        if (value instanceof Ids.Id id) {
            return id.value();
        }
        if (value instanceof Selector<?> selector) {
            return selector.toWire();
        }
        if (value instanceof Secret secret) {
            return secret.reveal();
        }
        if (value instanceof Command command) {
            return encode(command.toWire());
        }
        if (value instanceof byte[] bytes) {
            return Base64.getEncoder().encodeToString(bytes);
        }
        if (value instanceof Map<?, ?> map) {
            Map<String, Object> result = new LinkedHashMap<>();
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                if (!(entry.getKey() instanceof String key)) {
                    throw new IllegalArgumentException("wire object keys must be strings");
                }
                result.put(key, encode(entry.getValue()));
            }
            return result;
        }
        if (value instanceof Iterable<?> iterable) {
            List<Object> result = new ArrayList<>();
            for (Object item : iterable) {
                result.add(encode(item));
            }
            return result;
        }
        throw new IllegalArgumentException("unsupported wire value " + value.getClass().getName());
    }

    public static String json(Map<String, Object> value) {
        return Json.stringify(encode(value));
    }
}
