// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable script-repl-open request. Protocol v12; authority: local-admin. */
public final class ScriptReplOpenRequest implements WireValue {

    private ScriptReplOpenRequest(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }


    public static ScriptReplOpenRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ScriptReplOpenRequest");
        Builder builder = builder();
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ScriptReplOpenRequest that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "ScriptReplOpenRequest" + toWire(); }

    public static final class Builder {

        public ScriptReplOpenRequest build() { return new ScriptReplOpenRequest(this); }
    }
}
