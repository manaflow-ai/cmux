// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalClipboardHost implements WireValue {
    private final TerminalClipboardHostKind kind;
    private final Field<String> name;

    private TerminalClipboardHost(Builder builder) {
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        this.name = builder.name;
    }

    public static Builder builder() { return new Builder(); }

    public TerminalClipboardHostKind kind() { return kind; }
    public Field<String> name() { return name; }

    public static TerminalClipboardHost fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalClipboardHost");
        Builder builder = builder();
        Object rawKind = Wire.required(object, "kind");
        builder.kind(TerminalClipboardHostKind.fromWire(rawKind));
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(Wire.string(rawName, "TerminalClipboardHost.name"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "kind", kind);
        Wire.put(object, "name", name);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalClipboardHost that)) return false;
        return Objects.equals(kind, that.kind) && Objects.equals(name, that.name);
    }

    @Override
    public int hashCode() { return Objects.hash(kind, name); }

    @Override
    public String toString() { return "TerminalClipboardHost" + toWire(); }

    public static final class Builder {
        private TerminalClipboardHostKind kind;
        private boolean kindSet;
        private Field<String> name = Field.omitted();

        public Builder kind(TerminalClipboardHostKind value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = Field.of(value);
            return this;
        }
        public TerminalClipboardHost build() { return new TerminalClipboardHost(this); }
    }
}
