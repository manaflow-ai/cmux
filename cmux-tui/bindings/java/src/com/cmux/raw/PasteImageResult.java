// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class PasteImageResult implements WireValue {
    private final boolean accepted;

    private PasteImageResult(Builder builder) {
        if (!builder.acceptedSet) throw new IllegalArgumentException("accepted is required");
        this.accepted = builder.accepted;
    }

    public static Builder builder() { return new Builder(); }

    public boolean accepted() { return accepted; }

    public static PasteImageResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PasteImageResult");
        Builder builder = builder();
        Object rawAccepted = Wire.required(object, "accepted");
        builder.accepted(Wire.bool(rawAccepted, "PasteImageResult.accepted"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "accepted", accepted);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PasteImageResult that)) return false;
        return Objects.equals(accepted, that.accepted);
    }

    @Override
    public int hashCode() { return Objects.hash(accepted); }

    @Override
    public String toString() { return "PasteImageResult" + toWire(); }

    public static final class Builder {
        private Boolean accepted;
        private boolean acceptedSet;

        public Builder accepted(boolean value) {
            this.accepted = value;
            this.acceptedSet = true;
            return this;
        }
        public PasteImageResult build() { return new PasteImageResult(this); }
    }
}
