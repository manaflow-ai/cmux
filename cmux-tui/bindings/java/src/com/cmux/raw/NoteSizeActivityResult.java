// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class NoteSizeActivityResult implements WireValue {
    private final boolean changed;
    private final String participant;

    private NoteSizeActivityResult(Builder builder) {
        if (!builder.changedSet) throw new IllegalArgumentException("changed is required");
        this.changed = builder.changed;
        if (!builder.participantSet) throw new IllegalArgumentException("participant is required");
        this.participant = Wire.nonNull(builder.participant, "participant");
    }

    public static Builder builder() { return new Builder(); }

    public boolean changed() { return changed; }
    public String participant() { return participant; }

    public static NoteSizeActivityResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NoteSizeActivityResult");
        Builder builder = builder();
        Object rawChanged = Wire.required(object, "changed");
        builder.changed(Wire.bool(rawChanged, "NoteSizeActivityResult.changed"));
        Object rawParticipant = Wire.required(object, "participant");
        builder.participant(Wire.string(rawParticipant, "NoteSizeActivityResult.participant"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "changed", changed);
        Wire.put(object, "participant", participant);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NoteSizeActivityResult that)) return false;
        return Objects.equals(changed, that.changed) && Objects.equals(participant, that.participant);
    }

    @Override
    public int hashCode() { return Objects.hash(changed, participant); }

    @Override
    public String toString() { return "NoteSizeActivityResult" + toWire(); }

    public static final class Builder {
        private Boolean changed;
        private boolean changedSet;
        private String participant;
        private boolean participantSet;

        public Builder changed(boolean value) {
            this.changed = value;
            this.changedSet = true;
            return this;
        }
        public Builder participant(String value) {
            this.participant = value;
            this.participantSet = true;
            return this;
        }
        public NoteSizeActivityResult build() { return new NoteSizeActivityResult(this); }
    }
}
