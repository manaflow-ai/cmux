// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable get-appearance request. Protocol v12; authority: control. */
public final class GetAppearanceRequest implements WireValue {
    private final Field<Boolean> includePath;

    private GetAppearanceRequest(Builder builder) {
        this.includePath = builder.includePath;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> includePath() { return includePath; }

    public static GetAppearanceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "GetAppearanceRequest");
        Builder builder = builder();
        Object rawIncludePath = Wire.optional(object, "include_path");
        if (!Wire.isMissing(rawIncludePath)) {
            builder.includePath(rawIncludePath == null ? null : Wire.bool(rawIncludePath, "GetAppearanceRequest.include_path"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "include_path", includePath);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof GetAppearanceRequest that)) return false;
        return Objects.equals(includePath, that.includePath);
    }

    @Override
    public int hashCode() { return Objects.hash(includePath); }

    @Override
    public String toString() { return "GetAppearanceRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> includePath = Field.omitted();

        public Builder includePath(Boolean value) {
            this.includePath = Field.ofNullable(value);
            return this;
        }
        public GetAppearanceRequest build() { return new GetAppearanceRequest(this); }
    }
}
