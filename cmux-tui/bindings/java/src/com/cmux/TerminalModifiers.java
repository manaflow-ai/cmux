package com.cmux;

import java.util.LinkedHashMap;
import java.util.Map;

public record TerminalModifiers(
    boolean shift,
    boolean control,
    boolean alt,
    boolean superKey,
    boolean capsLock,
    boolean numLock
) {
    public static TerminalModifiers none() {
        return new TerminalModifiers(false, false, false, false, false, false);
    }

    Map<String, Object> toMap() {
        Map<String, Object> value = new LinkedHashMap<>();
        value.put("shift", shift);
        value.put("control", control);
        value.put("alt", alt);
        value.put("super", superKey);
        value.put("caps_lock", capsLock);
        value.put("num_lock", numLock);
        return value;
    }
}
