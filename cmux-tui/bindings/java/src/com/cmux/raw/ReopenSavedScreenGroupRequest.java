// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable reopen-saved-screen-group request. Protocol v12; authority: control. */
public final class ReopenSavedScreenGroupRequest implements WireValue {
    private final String saved;
    private final Field<UInt64> workspace;

    private ReopenSavedScreenGroupRequest(Builder builder) {
        if (!builder.savedSet) throw new IllegalArgumentException("saved is required");
        this.saved = Wire.nonNull(builder.saved, "saved");
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public String saved() { return saved; }
    public Field<UInt64> workspace() { return workspace; }

    public static ReopenSavedScreenGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReopenSavedScreenGroupRequest");
        Builder builder = builder();
        Object rawSaved = Wire.required(object, "saved");
        builder.saved(Wire.string(rawSaved, "ReopenSavedScreenGroupRequest.saved"));
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "ReopenSavedScreenGroupRequest.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "saved", saved);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReopenSavedScreenGroupRequest that)) return false;
        return Objects.equals(saved, that.saved) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(saved, workspace); }

    @Override
    public String toString() { return "ReopenSavedScreenGroupRequest" + toWire(); }

    public static final class Builder {
        private String saved;
        private boolean savedSet;
        private Field<UInt64> workspace = Field.omitted();

        public Builder saved(String value) {
            this.saved = value;
            this.savedSet = true;
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public ReopenSavedScreenGroupRequest build() { return new ReopenSavedScreenGroupRequest(this); }
    }
}
