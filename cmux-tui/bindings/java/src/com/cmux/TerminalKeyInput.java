package com.cmux;

import java.util.LinkedHashMap;
import java.util.Map;

public record TerminalKeyInput(
    TerminalKey key,
    TerminalModifiers mods,
    TerminalModifiers consumedMods,
    String utf8,
    String unshiftedCodepoint,
    TerminalKeyAction action,
    boolean macosOptionAsAlt
) {
    Map<String, Object> toMap() {
        Map<String, Object> value = new LinkedHashMap<>();
        value.put("key", key.wireName());
        value.put("mods", mods.toMap());
        value.put("consumed_mods", consumedMods.toMap());
        value.put("utf8", utf8);
        value.put("unshifted_codepoint", unshiftedCodepoint);
        value.put("action", action == null ? null : action.wireName());
        value.put("macos_option_as_alt", macosOptionAsAlt);
        return value;
    }
}
