// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-client-info request. Protocol v6; authority: control. */
public final class SetClientInfoRequest implements WireValue {
    private final Field<List<String>> capabilities;
    private final Field<String> kind;
    private final Field<String> name;

    private SetClientInfoRequest(Builder builder) {
        this.capabilities = builder.capabilities.map(value -> List.copyOf(value));
        this.kind = builder.kind;
        this.name = builder.name;
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<String>> capabilities() { return capabilities; }
    public Field<String> kind() { return kind; }
    public Field<String> name() { return name; }

    public static SetClientInfoRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetClientInfoRequest");
        Builder builder = builder();
        Object rawCapabilities = Wire.optional(object, "capabilities");
        if (!Wire.isMissing(rawCapabilities)) {
            builder.capabilities(rawCapabilities == null ? null : Wire.array(rawCapabilities, "SetClientInfoRequest.capabilities", item -> Wire.string(item, "SetClientInfoRequest.capabilities item")));
        }
        Object rawKind = Wire.optional(object, "kind");
        if (!Wire.isMissing(rawKind)) {
            builder.kind(rawKind == null ? null : Wire.string(rawKind, "SetClientInfoRequest.kind"));
        }
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "SetClientInfoRequest.name"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "capabilities", capabilities);
        Wire.put(object, "kind", kind);
        Wire.put(object, "name", name);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetClientInfoRequest that)) return false;
        return Objects.equals(capabilities, that.capabilities) && Objects.equals(kind, that.kind) && Objects.equals(name, that.name);
    }

    @Override
    public int hashCode() { return Objects.hash(capabilities, kind, name); }

    @Override
    public String toString() { return "SetClientInfoRequest" + toWire(); }

    public static final class Builder {
        private Field<List<String>> capabilities = Field.omitted();
        private Field<String> kind = Field.omitted();
        private Field<String> name = Field.omitted();

        public Builder capabilities(List<String> value) {
            this.capabilities = Field.ofNullable(value);
            return this;
        }
        public Builder kind(String value) {
            this.kind = Field.ofNullable(value);
            return this;
        }
        public Builder name(String value) {
            this.name = Field.ofNullable(value);
            return this;
        }
        public SetClientInfoRequest build() { return new SetClientInfoRequest(this); }
    }
}
