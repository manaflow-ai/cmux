// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class DeclarativeLayoutLeaf implements WireValue, DeclarativeLayout {
    private final Field<List<String>> command;
    private final Field<String> cwd;

    private DeclarativeLayoutLeaf(Builder builder) {
        this.command = builder.command.map(value -> List.copyOf(value));
        this.cwd = builder.cwd;
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<String>> command() { return command; }
    public Field<String> cwd() { return cwd; }
    public String type() { return "leaf"; }

    public static DeclarativeLayoutLeaf fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DeclarativeLayoutLeaf");
        Builder builder = builder();
        Object rawCommand = Wire.optional(object, "command");
        if (!Wire.isMissing(rawCommand)) {
            builder.command(rawCommand == null ? null : Wire.array(rawCommand, "DeclarativeLayoutLeaf.command", item -> Wire.string(item, "DeclarativeLayoutLeaf.command item")));
        }
        Object rawCwd = Wire.optional(object, "cwd");
        if (!Wire.isMissing(rawCwd)) {
            builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "DeclarativeLayoutLeaf.cwd"));
        }
        Object rawType = Wire.required(object, "type");
        ProtocolSupport.literal(rawType, "leaf", "DeclarativeLayoutLeaf.type");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "command", command);
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "type", "leaf");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DeclarativeLayoutLeaf that)) return false;
        return Objects.equals(command, that.command) && Objects.equals(cwd, that.cwd);
    }

    @Override
    public int hashCode() { return Objects.hash(command, cwd); }

    @Override
    public String toString() { return "DeclarativeLayoutLeaf" + toWire(); }

    public static final class Builder {
        private Field<List<String>> command = Field.omitted();
        private Field<String> cwd = Field.omitted();

        public Builder command(List<String> value) {
            this.command = Field.ofNullable(value);
            return this;
        }
        public Builder cwd(String value) {
            this.cwd = Field.ofNullable(value);
            return this;
        }
        public DeclarativeLayoutLeaf build() { return new DeclarativeLayoutLeaf(this); }
    }
}
