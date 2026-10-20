// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class FrontendJournalEventFocus implements WireValue, FrontendJournalEvent {
    private final Field<String> contentId;
    private final String eventId;
    private final String frontendProjectionId;
    private final String generation;
    private final Field<String> paneId;
    private final Field<String> screenId;
    private final Field<String> tabId;
    private final FrontendFocusTarget target;
    private final Field<String> workspaceId;

    private FrontendJournalEventFocus(Builder builder) {
        this.contentId = builder.contentId;
        if (!builder.eventIdSet) throw new IllegalArgumentException("event_id is required");
        this.eventId = Wire.nonNull(builder.eventId, "event_id");
        if (!builder.frontendProjectionIdSet) throw new IllegalArgumentException("frontend_projection_id is required");
        this.frontendProjectionId = Wire.nonNull(builder.frontendProjectionId, "frontend_projection_id");
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        this.paneId = builder.paneId;
        this.screenId = builder.screenId;
        this.tabId = builder.tabId;
        if (!builder.targetSet) throw new IllegalArgumentException("target is required");
        this.target = Wire.nonNull(builder.target, "target");
        this.workspaceId = builder.workspaceId;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> contentId() { return contentId; }
    public String eventId() { return eventId; }
    public String frontendProjectionId() { return frontendProjectionId; }
    public String generation() { return generation; }
    public String kind() { return "focus"; }
    public Field<String> paneId() { return paneId; }
    public Field<String> screenId() { return screenId; }
    public Field<String> tabId() { return tabId; }
    public FrontendFocusTarget target() { return target; }
    public Field<String> workspaceId() { return workspaceId; }

    public static FrontendJournalEventFocus fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FrontendJournalEventFocus");
        Builder builder = builder();
        Object rawContentId = Wire.optional(object, "content_id");
        if (!Wire.isMissing(rawContentId)) {
            builder.contentId(rawContentId == null ? null : Wire.string(rawContentId, "FrontendJournalEventFocus.content_id"));
        }
        Object rawEventId = Wire.required(object, "event_id");
        builder.eventId(Wire.string(rawEventId, "FrontendJournalEventFocus.event_id"));
        Object rawFrontendProjectionId = Wire.required(object, "frontend_projection_id");
        builder.frontendProjectionId(Wire.string(rawFrontendProjectionId, "FrontendJournalEventFocus.frontend_projection_id"));
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.string(rawGeneration, "FrontendJournalEventFocus.generation"));
        Object rawKind = Wire.required(object, "kind");
        ProtocolSupport.literal(rawKind, "focus", "FrontendJournalEventFocus.kind");
        Object rawPaneId = Wire.optional(object, "pane_id");
        if (!Wire.isMissing(rawPaneId)) {
            builder.paneId(rawPaneId == null ? null : Wire.string(rawPaneId, "FrontendJournalEventFocus.pane_id"));
        }
        Object rawScreenId = Wire.optional(object, "screen_id");
        if (!Wire.isMissing(rawScreenId)) {
            builder.screenId(rawScreenId == null ? null : Wire.string(rawScreenId, "FrontendJournalEventFocus.screen_id"));
        }
        Object rawTabId = Wire.optional(object, "tab_id");
        if (!Wire.isMissing(rawTabId)) {
            builder.tabId(rawTabId == null ? null : Wire.string(rawTabId, "FrontendJournalEventFocus.tab_id"));
        }
        Object rawTarget = Wire.required(object, "target");
        builder.target(FrontendFocusTarget.fromWire(rawTarget));
        Object rawWorkspaceId = Wire.optional(object, "workspace_id");
        if (!Wire.isMissing(rawWorkspaceId)) {
            builder.workspaceId(rawWorkspaceId == null ? null : Wire.string(rawWorkspaceId, "FrontendJournalEventFocus.workspace_id"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "content_id", contentId);
        Wire.put(object, "event_id", eventId);
        Wire.put(object, "frontend_projection_id", frontendProjectionId);
        Wire.put(object, "generation", generation);
        Wire.put(object, "kind", "focus");
        Wire.put(object, "pane_id", paneId);
        Wire.put(object, "screen_id", screenId);
        Wire.put(object, "tab_id", tabId);
        Wire.put(object, "target", target);
        Wire.put(object, "workspace_id", workspaceId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FrontendJournalEventFocus that)) return false;
        return Objects.equals(contentId, that.contentId) && Objects.equals(eventId, that.eventId) && Objects.equals(frontendProjectionId, that.frontendProjectionId) && Objects.equals(generation, that.generation) && Objects.equals(paneId, that.paneId) && Objects.equals(screenId, that.screenId) && Objects.equals(tabId, that.tabId) && Objects.equals(target, that.target) && Objects.equals(workspaceId, that.workspaceId);
    }

    @Override
    public int hashCode() { return Objects.hash(contentId, eventId, frontendProjectionId, generation, paneId, screenId, tabId, target, workspaceId); }

    @Override
    public String toString() { return "FrontendJournalEventFocus" + toWire(); }

    public static final class Builder {
        private Field<String> contentId = Field.omitted();
        private String eventId;
        private boolean eventIdSet;
        private String frontendProjectionId;
        private boolean frontendProjectionIdSet;
        private String generation;
        private boolean generationSet;
        private Field<String> paneId = Field.omitted();
        private Field<String> screenId = Field.omitted();
        private Field<String> tabId = Field.omitted();
        private FrontendFocusTarget target;
        private boolean targetSet;
        private Field<String> workspaceId = Field.omitted();

        public Builder contentId(String value) {
            this.contentId = Field.ofNullable(value);
            return this;
        }
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
        public Builder paneId(String value) {
            this.paneId = Field.ofNullable(value);
            return this;
        }
        public Builder screenId(String value) {
            this.screenId = Field.ofNullable(value);
            return this;
        }
        public Builder tabId(String value) {
            this.tabId = Field.ofNullable(value);
            return this;
        }
        public Builder target(FrontendFocusTarget value) {
            this.target = value;
            this.targetSet = true;
            return this;
        }
        public Builder workspaceId(String value) {
            this.workspaceId = Field.ofNullable(value);
            return this;
        }
        public FrontendJournalEventFocus build() { return new FrontendJournalEventFocus(this); }
    }
}
