// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable note-size-activity request. Protocol v12; authority: control. */
public final class NoteSizeActivityRequest implements WireValue {
    private final Field<SizeActivityKind> kind;
    private final UInt64 surface;
    private final Field<String> view;

    private NoteSizeActivityRequest(Builder builder) {
        this.kind = builder.kind;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.view = builder.view;
    }

    public static Builder builder() { return new Builder(); }

    public Field<SizeActivityKind> kind() { return kind; }
    public UInt64 surface() { return surface; }
    public Field<String> view() { return view; }

    public static NoteSizeActivityRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NoteSizeActivityRequest");
        Builder builder = builder();
        Object rawKind = Wire.optional(object, "kind");
        if (!Wire.isMissing(rawKind)) {
            builder.kind(rawKind == null ? null : SizeActivityKind.fromWire(rawKind));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "NoteSizeActivityRequest.surface"));
        Object rawView = Wire.optional(object, "view");
        if (!Wire.isMissing(rawView)) {
            builder.view(rawView == null ? null : Wire.string(rawView, "NoteSizeActivityRequest.view"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "kind", kind);
        Wire.put(object, "surface", surface);
        Wire.put(object, "view", view);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NoteSizeActivityRequest that)) return false;
        return Objects.equals(kind, that.kind) && Objects.equals(surface, that.surface) && Objects.equals(view, that.view);
    }

    @Override
    public int hashCode() { return Objects.hash(kind, surface, view); }

    @Override
    public String toString() { return "NoteSizeActivityRequest" + toWire(); }

    public static final class Builder {
        private Field<SizeActivityKind> kind = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> view = Field.omitted();

        public Builder kind(SizeActivityKind value) {
            this.kind = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder view(String value) {
            this.view = Field.ofNullable(value);
            return this;
        }
        public NoteSizeActivityRequest build() { return new NoteSizeActivityRequest(this); }
    }
}
