// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class CancelCreatingInputResult implements WireValue {
    private final boolean cancelled;

    private CancelCreatingInputResult(Builder builder) {
        if (!builder.cancelledSet) throw new IllegalArgumentException("cancelled is required");
        this.cancelled = builder.cancelled;
    }

    public static Builder builder() { return new Builder(); }

    public boolean cancelled() { return cancelled; }

    public static CancelCreatingInputResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CancelCreatingInputResult");
        Builder builder = builder();
        Object rawCancelled = Wire.required(object, "cancelled");
        builder.cancelled(Wire.bool(rawCancelled, "CancelCreatingInputResult.cancelled"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cancelled", cancelled);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CancelCreatingInputResult that)) return false;
        return Objects.equals(cancelled, that.cancelled);
    }

    @Override
    public int hashCode() { return Objects.hash(cancelled); }

    @Override
    public String toString() { return "CancelCreatingInputResult" + toWire(); }

    public static final class Builder {
        private Boolean cancelled;
        private boolean cancelledSet;

        public Builder cancelled(boolean value) {
            this.cancelled = value;
            this.cancelledSet = true;
            return this;
        }
        public CancelCreatingInputResult build() { return new CancelCreatingInputResult(this); }
    }
}
