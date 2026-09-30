// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class LayoutUndoConfirmationRequired implements WireValue {
    private final List<UInt64> closesPanes;
    private final UInt64 revision;
    private final UInt64 screen;

    private LayoutUndoConfirmationRequired(Builder builder) {
        if (!builder.closesPanesSet) throw new IllegalArgumentException("closes_panes is required");
        this.closesPanes = List.copyOf(Wire.nonNull(builder.closesPanes, "closes_panes"));
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = Wire.nonNull(builder.screen, "screen");
    }

    public static Builder builder() { return new Builder(); }

    public List<UInt64> closesPanes() { return closesPanes; }
    public Boolean confirmationRequired() { return true; }
    public UInt64 revision() { return revision; }
    public UInt64 screen() { return screen; }
    public Boolean undone() { return false; }

    public static LayoutUndoConfirmationRequired fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LayoutUndoConfirmationRequired");
        Builder builder = builder();
        Object rawClosesPanes = Wire.required(object, "closes_panes");
        builder.closesPanes(Wire.array(rawClosesPanes, "LayoutUndoConfirmationRequired.closes_panes", item -> Wire.uint64(item, "LayoutUndoConfirmationRequired.closes_panes item")));
        Object rawConfirmationRequired = Wire.required(object, "confirmation_required");
        ProtocolSupport.literal(rawConfirmationRequired, true, "LayoutUndoConfirmationRequired.confirmation_required");
        Object rawRevision = Wire.required(object, "revision");
        builder.revision(Wire.uint64(rawRevision, "LayoutUndoConfirmationRequired.revision"));
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(Wire.uint64(rawScreen, "LayoutUndoConfirmationRequired.screen"));
        Object rawUndone = Wire.required(object, "undone");
        ProtocolSupport.literal(rawUndone, false, "LayoutUndoConfirmationRequired.undone");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "closes_panes", closesPanes);
        Wire.put(object, "confirmation_required", true);
        Wire.put(object, "revision", revision);
        Wire.put(object, "screen", screen);
        Wire.put(object, "undone", false);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LayoutUndoConfirmationRequired that)) return false;
        return Objects.equals(closesPanes, that.closesPanes) && Objects.equals(revision, that.revision) && Objects.equals(screen, that.screen);
    }

    @Override
    public int hashCode() { return Objects.hash(closesPanes, revision, screen); }

    @Override
    public String toString() { return "LayoutUndoConfirmationRequired" + toWire(); }

    public static final class Builder {
        private List<UInt64> closesPanes;
        private boolean closesPanesSet;
        private UInt64 revision;
        private boolean revisionSet;
        private UInt64 screen;
        private boolean screenSet;

        public Builder closesPanes(List<UInt64> value) {
            this.closesPanes = value;
            this.closesPanesSet = true;
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
        public LayoutUndoConfirmationRequired build() { return new LayoutUndoConfirmationRequired(this); }
    }
}
