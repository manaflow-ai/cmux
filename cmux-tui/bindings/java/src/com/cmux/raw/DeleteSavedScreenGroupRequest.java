// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable delete-saved-screen-group request. Protocol v12; authority: control. */
public final class DeleteSavedScreenGroupRequest implements WireValue {
    private final String saved;

    private DeleteSavedScreenGroupRequest(Builder builder) {
        if (!builder.savedSet) throw new IllegalArgumentException("saved is required");
        this.saved = Wire.nonNull(builder.saved, "saved");
    }

    public static Builder builder() { return new Builder(); }

    public String saved() { return saved; }

    public static DeleteSavedScreenGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DeleteSavedScreenGroupRequest");
        Builder builder = builder();
        Object rawSaved = Wire.required(object, "saved");
        builder.saved(Wire.string(rawSaved, "DeleteSavedScreenGroupRequest.saved"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "saved", saved);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DeleteSavedScreenGroupRequest that)) return false;
        return Objects.equals(saved, that.saved);
    }

    @Override
    public int hashCode() { return Objects.hash(saved); }

    @Override
    public String toString() { return "DeleteSavedScreenGroupRequest" + toWire(); }

    public static final class Builder {
        private String saved;
        private boolean savedSet;

        public Builder saved(String value) {
            this.saved = value;
            this.savedSet = true;
            return this;
        }
        public DeleteSavedScreenGroupRequest build() { return new DeleteSavedScreenGroupRequest(this); }
    }
}
