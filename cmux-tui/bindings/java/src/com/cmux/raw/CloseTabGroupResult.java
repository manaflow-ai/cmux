// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class CloseTabGroupResult implements WireValue {
    private final List<UInt64> closed;
    private final String group;
    /** With end_terminals: the member terminals the close ended. */
    private final Field<List<TabGroupEndedTerminal>> terminals;
    private final Map<String, Object> additionalProperties;

    private CloseTabGroupResult(Builder builder) {
        if (!builder.closedSet) throw new IllegalArgumentException("closed is required");
        this.closed = List.copyOf(Wire.nonNull(builder.closed, "closed"));
        if (!builder.groupSet) throw new IllegalArgumentException("group is required");
        this.group = Wire.nonNull(builder.group, "group");
        this.terminals = builder.terminals.map(value -> List.copyOf(value));
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public List<UInt64> closed() { return closed; }
    public String group() { return group; }
    public Field<List<TabGroupEndedTerminal>> terminals() { return terminals; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static CloseTabGroupResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloseTabGroupResult");
        Builder builder = builder();
        Object rawClosed = Wire.required(object, "closed");
        builder.closed(Wire.array(rawClosed, "CloseTabGroupResult.closed", item -> Wire.uint64(item, "CloseTabGroupResult.closed item")));
        Object rawGroup = Wire.required(object, "group");
        builder.group(Wire.string(rawGroup, "CloseTabGroupResult.group"));
        Object rawTerminals = Wire.optional(object, "terminals");
        if (!Wire.isMissing(rawTerminals)) {
            builder.terminals(Wire.array(rawTerminals, "CloseTabGroupResult.terminals", item -> TabGroupEndedTerminal.fromWire(item)));
        }
        List<String> known = List.of("closed", "group", "terminals");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "closed", closed);
        Wire.put(object, "group", group);
        Wire.put(object, "terminals", terminals);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloseTabGroupResult that)) return false;
        return Objects.equals(closed, that.closed) && Objects.equals(group, that.group) && Objects.equals(terminals, that.terminals) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(closed, group, terminals, additionalProperties); }

    @Override
    public String toString() { return "CloseTabGroupResult" + toWire(); }

    public static final class Builder {
        private List<UInt64> closed;
        private boolean closedSet;
        private String group;
        private boolean groupSet;
        private Field<List<TabGroupEndedTerminal>> terminals = Field.omitted();
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder closed(List<UInt64> value) {
            this.closed = value;
            this.closedSet = true;
            return this;
        }
        public Builder group(String value) {
            this.group = value;
            this.groupSet = true;
            return this;
        }
        public Builder terminals(List<TabGroupEndedTerminal> value) {
            this.terminals = Field.of(value);
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public CloseTabGroupResult build() { return new CloseTabGroupResult(this); }
    }
}
