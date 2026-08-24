// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SetCellPixelsResult implements WireValue {
    private final List<CellPixelFailure> failures;
    private final List<CellPixelResize> resizes;

    private SetCellPixelsResult(Builder builder) {
        if (!builder.failuresSet) throw new IllegalArgumentException("failures is required");
        this.failures = List.copyOf(Wire.nonNull(builder.failures, "failures"));
        if (!builder.resizesSet) throw new IllegalArgumentException("resizes is required");
        this.resizes = List.copyOf(Wire.nonNull(builder.resizes, "resizes"));
    }

    public static Builder builder() { return new Builder(); }

    public List<CellPixelFailure> failures() { return failures; }
    public List<CellPixelResize> resizes() { return resizes; }

    public static SetCellPixelsResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetCellPixelsResult");
        Builder builder = builder();
        Object rawFailures = Wire.required(object, "failures");
        builder.failures(Wire.array(rawFailures, "SetCellPixelsResult.failures", item -> CellPixelFailure.fromWire(item)));
        Object rawResizes = Wire.required(object, "resizes");
        builder.resizes(Wire.array(rawResizes, "SetCellPixelsResult.resizes", item -> CellPixelResize.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "failures", failures);
        Wire.put(object, "resizes", resizes);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetCellPixelsResult that)) return false;
        return Objects.equals(failures, that.failures) && Objects.equals(resizes, that.resizes);
    }

    @Override
    public int hashCode() { return Objects.hash(failures, resizes); }

    @Override
    public String toString() { return "SetCellPixelsResult" + toWire(); }

    public static final class Builder {
        private List<CellPixelFailure> failures;
        private boolean failuresSet;
        private List<CellPixelResize> resizes;
        private boolean resizesSet;

        public Builder failures(List<CellPixelFailure> value) {
            this.failures = value;
            this.failuresSet = true;
            return this;
        }
        public Builder resizes(List<CellPixelResize> value) {
            this.resizes = value;
            this.resizesSet = true;
            return this;
        }
        public SetCellPixelsResult build() { return new SetCellPixelsResult(this); }
    }
}
