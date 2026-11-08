// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class FrontendJournalEventViewport implements WireValue, FrontendJournalEvent {
    private final String eventId;
    private final String frontendProjectionId;
    private final String generation;
    private final UInt64 offset;
    private final Field<String> screenId;
    private final boolean settled;
    private final UInt64 target;

    private FrontendJournalEventViewport(Builder builder) {
        if (!builder.eventIdSet) throw new IllegalArgumentException("event_id is required");
        this.eventId = Wire.nonNull(builder.eventId, "event_id");
        if (!builder.frontendProjectionIdSet) throw new IllegalArgumentException("frontend_projection_id is required");
        this.frontendProjectionId = Wire.nonNull(builder.frontendProjectionId, "frontend_projection_id");
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        if (!builder.offsetSet) throw new IllegalArgumentException("offset is required");
        this.offset = Wire.nonNull(builder.offset, "offset");
        this.screenId = builder.screenId;
        if (!builder.settledSet) throw new IllegalArgumentException("settled is required");
        this.settled = builder.settled;
        if (!builder.targetSet) throw new IllegalArgumentException("target is required");
        this.target = Wire.nonNull(builder.target, "target");
    }

    public static Builder builder() { return new Builder(); }

    public String eventId() { return eventId; }
    public String frontendProjectionId() { return frontendProjectionId; }
    public String generation() { return generation; }
    public String kind() { return "viewport"; }
    public UInt64 offset() { return offset; }
    public Field<String> screenId() { return screenId; }
    public boolean settled() { return settled; }
    public UInt64 target() { return target; }

    public static FrontendJournalEventViewport fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FrontendJournalEventViewport");
        Builder builder = builder();
        Object rawEventId = Wire.required(object, "event_id");
        builder.eventId(Wire.string(rawEventId, "FrontendJournalEventViewport.event_id"));
        Object rawFrontendProjectionId = Wire.required(object, "frontend_projection_id");
        builder.frontendProjectionId(Wire.string(rawFrontendProjectionId, "FrontendJournalEventViewport.frontend_projection_id"));
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.string(rawGeneration, "FrontendJournalEventViewport.generation"));
        Object rawKind = Wire.required(object, "kind");
        ProtocolSupport.literal(rawKind, "viewport", "FrontendJournalEventViewport.kind");
        Object rawOffset = Wire.required(object, "offset");
        builder.offset(Wire.uint64(rawOffset, "FrontendJournalEventViewport.offset"));
        Object rawScreenId = Wire.optional(object, "screen_id");
        if (!Wire.isMissing(rawScreenId)) {
            builder.screenId(rawScreenId == null ? null : Wire.string(rawScreenId, "FrontendJournalEventViewport.screen_id"));
        }
        Object rawSettled = Wire.required(object, "settled");
        builder.settled(Wire.bool(rawSettled, "FrontendJournalEventViewport.settled"));
        Object rawTarget = Wire.required(object, "target");
        builder.target(Wire.uint64(rawTarget, "FrontendJournalEventViewport.target"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "event_id", eventId);
        Wire.put(object, "frontend_projection_id", frontendProjectionId);
        Wire.put(object, "generation", generation);
        Wire.put(object, "kind", "viewport");
        Wire.put(object, "offset", offset);
        Wire.put(object, "screen_id", screenId);
        Wire.put(object, "settled", settled);
        Wire.put(object, "target", target);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FrontendJournalEventViewport that)) return false;
        return Objects.equals(eventId, that.eventId) && Objects.equals(frontendProjectionId, that.frontendProjectionId) && Objects.equals(generation, that.generation) && Objects.equals(offset, that.offset) && Objects.equals(screenId, that.screenId) && Objects.equals(settled, that.settled) && Objects.equals(target, that.target);
    }

    @Override
    public int hashCode() { return Objects.hash(eventId, frontendProjectionId, generation, offset, screenId, settled, target); }

    @Override
    public String toString() { return "FrontendJournalEventViewport" + toWire(); }

    public static final class Builder {
        private String eventId;
        private boolean eventIdSet;
        private String frontendProjectionId;
        private boolean frontendProjectionIdSet;
        private String generation;
        private boolean generationSet;
        private UInt64 offset;
        private boolean offsetSet;
        private Field<String> screenId = Field.omitted();
        private Boolean settled;
        private boolean settledSet;
        private UInt64 target;
        private boolean targetSet;

        public Builder eventId(String value) {
            this.eventId = value;
            this.eventIdSet = true;
            return this;
        }
        public Builder frontendProjectionId(String value) {
            this.frontendProjectionId = value;
            this.frontendProjectionIdSet = true;
            return this;
        }
        public Builder generation(String value) {
            this.generation = value;
            this.generationSet = true;
            return this;
        }
        public Builder offset(UInt64 value) {
            this.offset = value;
            this.offsetSet = true;
            return this;
        }
        public Builder screenId(String value) {
            this.screenId = Field.ofNullable(value);
            return this;
        }
        public Builder settled(boolean value) {
            this.settled = value;
            this.settledSet = true;
            return this;
        }
        public Builder target(UInt64 value) {
            this.target = value;
            this.targetSet = true;
            return this;
        }
        public FrontendJournalEventViewport build() { return new FrontendJournalEventViewport(this); }
    }
}
