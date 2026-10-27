// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentCliIntentsRecordResult implements WireValue {
    private final boolean changed;
    private final List<AgentCLIStoredIntent> intents;

    private AgentCliIntentsRecordResult(Builder builder) {
        if (!builder.changedSet) throw new IllegalArgumentException("changed is required");
        this.changed = builder.changed;
        if (!builder.intentsSet) throw new IllegalArgumentException("intents is required");
        this.intents = List.copyOf(Wire.nonNull(builder.intents, "intents"));
    }

    public static Builder builder() { return new Builder(); }

    public boolean changed() { return changed; }
    public List<AgentCLIStoredIntent> intents() { return intents; }

    public static AgentCliIntentsRecordResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentCliIntentsRecordResult");
        Builder builder = builder();
        Object rawChanged = Wire.required(object, "changed");
        builder.changed(Wire.bool(rawChanged, "AgentCliIntentsRecordResult.changed"));
        Object rawIntents = Wire.required(object, "intents");
        builder.intents(Wire.array(rawIntents, "AgentCliIntentsRecordResult.intents", item -> AgentCLIStoredIntent.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "changed", changed);
        Wire.put(object, "intents", intents);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentCliIntentsRecordResult that)) return false;
        return Objects.equals(changed, that.changed) && Objects.equals(intents, that.intents);
    }

    @Override
    public int hashCode() { return Objects.hash(changed, intents); }

    @Override
    public String toString() { return "AgentCliIntentsRecordResult" + toWire(); }

    public static final class Builder {
        private Boolean changed;
        private boolean changedSet;
        private List<AgentCLIStoredIntent> intents;
        private boolean intentsSet;

        public Builder changed(boolean value) {
            this.changed = value;
            this.changedSet = true;
            return this;
        }
        public Builder intents(List<AgentCLIStoredIntent> value) {
            this.intents = value;
            this.intentsSet = true;
            return this;
        }
        public AgentCliIntentsRecordResult build() { return new AgentCliIntentsRecordResult(this); }
    }
}
