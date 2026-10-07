// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class LayoutUndoUndone implements WireValue {
    private final Field<Boolean> confirmationRequired;
    private final UInt64 revision;
    private final UInt64 screen;

    private LayoutUndoUndone(Builder builder) {
        this.confirmationRequired = builder.confirmationRequired;
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = Wire.nonNull(builder.screen, "screen");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> confirmationRequired() { return confirmationRequired; }
    public UInt64 revision() { return revision; }
    public UInt64 screen() { return screen; }
    public Boolean undone() { return true; }

    public static LayoutUndoUndone fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LayoutUndoUndone");
        Builder builder = builder();
        Object rawConfirmationRequired = Wire.optional(object, "confirmation_required");
        if (!Wire.isMissing(rawConfirmationRequired)) {
            builder.confirmationRequired(ProtocolSupport.literal(rawConfirmationRequired, false, "LayoutUndoUndone.confirmation_required"));
        }
        Object rawRevision = Wire.required(object, "revision");
        builder.revision(Wire.uint64(rawRevision, "LayoutUndoUndone.revision"));
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(Wire.uint64(rawScreen, "LayoutUndoUndone.screen"));
        Object rawUndone = Wire.required(object, "undone");
        ProtocolSupport.literal(rawUndone, true, "LayoutUndoUndone.undone");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "confirmation_required", confirmationRequired);
        Wire.put(object, "revision", revision);
        Wire.put(object, "screen", screen);
        Wire.put(object, "undone", true);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LayoutUndoUndone that)) return false;
        return Objects.equals(confirmationRequired, that.confirmationRequired) && Objects.equals(revision, that.revision) && Objects.equals(screen, that.screen);
    }

    @Override
    public int hashCode() { return Objects.hash(confirmationRequired, revision, screen); }

    @Override
    public String toString() { return "LayoutUndoUndone" + toWire(); }

    public static final class Builder {
        private Field<Boolean> confirmationRequired = Field.omitted();
        private UInt64 revision;
        private boolean revisionSet;
        private UInt64 screen;
        private boolean screenSet;

        public Builder confirmationRequired(Boolean value) {
            ProtocolSupport.literal(value, false, "LayoutUndoUndone.confirmation_required");
            this.confirmationRequired = Field.of(value);
            return this;
        }
        public Builder revision(UInt64 value) {
            this.revision = value;
            this.revisionSet = true;
            return this;
        }
        public Builder screen(UInt64 value) {
            this.screen = value;
            this.screenSet = true;
            return this;
        }
        public LayoutUndoUndone build() { return new LayoutUndoUndone(this); }
    }
}
