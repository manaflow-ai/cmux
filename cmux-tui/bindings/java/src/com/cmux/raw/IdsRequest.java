// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable ids request. Protocol v6; authority: control. */
public final class IdsRequest implements WireValue {
    private final Field<IdsRequestKind> kind;

    private IdsRequest(Builder builder) {
        this.kind = builder.kind;
    }

    public static Builder builder() { return new Builder(); }

    public Field<IdsRequestKind> kind() { return kind; }

    public static IdsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "IdsRequest");
        Builder builder = builder();
        Object rawKind = Wire.optional(object, "kind");
        if (!Wire.isMissing(rawKind)) {
            builder.kind(rawKind == null ? null : IdsRequestKind.fromWire(rawKind));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "kind", kind);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof IdsRequest that)) return false;
        return Objects.equals(kind, that.kind);
    }

    @Override
    public int hashCode() { return Objects.hash(kind); }

    @Override
    public String toString() { return "IdsRequest" + toWire(); }

    public static final class Builder {
        private Field<IdsRequestKind> kind = Field.omitted();

        public Builder kind(IdsRequestKind value) {
            this.kind = Field.ofNullable(value);
            return this;
        }
        public IdsRequest build() { return new IdsRequest(this); }
    }
}
