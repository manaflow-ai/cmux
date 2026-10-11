// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-workspace-metadata request. Protocol v12; authority: control. */
public final class SetWorkspaceMetadataRequest implements WireValue {
    private final Field<String> color;
    private final Field<String> expectedGeneration;
    private final Field<UInt64> expectedRevision;
    private final Field<String> icon;
    private final Field<String> key;
    private final Field<Boolean> markedUnread;
    private final Field<String> mutationId;
    private final Field<String> origin;
    private final Field<Boolean> pinned;
    private final Field<String> title;
    private final Field<UInt64> workspace;

    private SetWorkspaceMetadataRequest(Builder builder) {
        this.color = builder.color;
        this.expectedGeneration = builder.expectedGeneration;
        this.expectedRevision = builder.expectedRevision;
        this.icon = builder.icon;
        this.key = builder.key;
        this.markedUnread = builder.markedUnread;
        this.mutationId = builder.mutationId;
        this.origin = builder.origin;
        this.pinned = builder.pinned;
        this.title = builder.title;
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> color() { return color; }
    public Field<String> expectedGeneration() { return expectedGeneration; }
    public Field<UInt64> expectedRevision() { return expectedRevision; }
    public Field<String> icon() { return icon; }
    public Field<String> key() { return key; }
    public Field<Boolean> markedUnread() { return markedUnread; }
    public Field<String> mutationId() { return mutationId; }
    public Field<String> origin() { return origin; }
    public Field<Boolean> pinned() { return pinned; }
    public Field<String> title() { return title; }
    public Field<UInt64> workspace() { return workspace; }

    public static SetWorkspaceMetadataRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetWorkspaceMetadataRequest");
        Builder builder = builder();
        Object rawColor = Wire.optional(object, "color");
        if (!Wire.isMissing(rawColor)) {
            builder.color(rawColor == null ? null : Wire.string(rawColor, "SetWorkspaceMetadataRequest.color"));
        }
        Object rawExpectedGeneration = Wire.optional(object, "expected_generation");
        if (!Wire.isMissing(rawExpectedGeneration)) {
            builder.expectedGeneration(rawExpectedGeneration == null ? null : Wire.string(rawExpectedGeneration, "SetWorkspaceMetadataRequest.expected_generation"));
        }
        Object rawExpectedRevision = Wire.optional(object, "expected_revision", "expected_terminal_revision");
        if (!Wire.isMissing(rawExpectedRevision)) {
            builder.expectedRevision(rawExpectedRevision == null ? null : Wire.uint64(rawExpectedRevision, "SetWorkspaceMetadataRequest.expected_revision"));
        }
        Object rawIcon = Wire.optional(object, "icon");
        if (!Wire.isMissing(rawIcon)) {
            builder.icon(rawIcon == null ? null : Wire.string(rawIcon, "SetWorkspaceMetadataRequest.icon"));
        }
        Object rawKey = Wire.optional(object, "key");
        if (!Wire.isMissing(rawKey)) {
            builder.key(rawKey == null ? null : Wire.string(rawKey, "SetWorkspaceMetadataRequest.key"));
        }
        Object rawMarkedUnread = Wire.optional(object, "marked_unread");
        if (!Wire.isMissing(rawMarkedUnread)) {
            builder.markedUnread(rawMarkedUnread == null ? null : Wire.bool(rawMarkedUnread, "SetWorkspaceMetadataRequest.marked_unread"));
        }
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "SetWorkspaceMetadataRequest.mutation_id"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "SetWorkspaceMetadataRequest.origin"));
        }
        Object rawPinned = Wire.optional(object, "pinned");
        if (!Wire.isMissing(rawPinned)) {
            builder.pinned(rawPinned == null ? null : Wire.bool(rawPinned, "SetWorkspaceMetadataRequest.pinned"));
        }
        Object rawTitle = Wire.optional(object, "title");
        if (!Wire.isMissing(rawTitle)) {
            builder.title(rawTitle == null ? null : Wire.string(rawTitle, "SetWorkspaceMetadataRequest.title"));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "SetWorkspaceMetadataRequest.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "color", color);
        Wire.put(object, "expected_generation", expectedGeneration);
        Wire.put(object, "expected_revision", expectedRevision);
        Wire.put(object, "icon", icon);
        Wire.put(object, "key", key);
        Wire.put(object, "marked_unread", markedUnread);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "origin", origin);
        Wire.put(object, "pinned", pinned);
        Wire.put(object, "title", title);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetWorkspaceMetadataRequest that)) return false;
        return Objects.equals(color, that.color) && Objects.equals(expectedGeneration, that.expectedGeneration) && Objects.equals(expectedRevision, that.expectedRevision) && Objects.equals(icon, that.icon) && Objects.equals(key, that.key) && Objects.equals(markedUnread, that.markedUnread) && Objects.equals(mutationId, that.mutationId) && Objects.equals(origin, that.origin) && Objects.equals(pinned, that.pinned) && Objects.equals(title, that.title) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(color, expectedGeneration, expectedRevision, icon, key, markedUnread, mutationId, origin, pinned, title, workspace); }

    @Override
    public String toString() { return "SetWorkspaceMetadataRequest" + toWire(); }

    public static final class Builder {
        private Field<String> color = Field.omitted();
        private Field<String> expectedGeneration = Field.omitted();
        private Field<UInt64> expectedRevision = Field.omitted();
        private Field<String> icon = Field.omitted();
        private Field<String> key = Field.omitted();
        private Field<Boolean> markedUnread = Field.omitted();
        private Field<String> mutationId = Field.omitted();
        private Field<String> origin = Field.omitted();
        private Field<Boolean> pinned = Field.omitted();
        private Field<String> title = Field.omitted();
        private Field<UInt64> workspace = Field.omitted();

        public Builder color(String value) {
            this.color = Field.ofNullable(value);
            return this;
        }
        public Builder expectedGeneration(String value) {
            this.expectedGeneration = Field.ofNullable(value);
            return this;
        }
        public Builder expectedRevision(UInt64 value) {
            this.expectedRevision = Field.ofNullable(value);
            return this;
        }
        public Builder icon(String value) {
            this.icon = Field.ofNullable(value);
            return this;
        }
        public Builder key(String value) {
            this.key = Field.ofNullable(value);
            return this;
        }
        public Builder markedUnread(Boolean value) {
            this.markedUnread = Field.ofNullable(value);
            return this;
        }
        public Builder mutationId(String value) {
            this.mutationId = Field.ofNullable(value);
            return this;
        }
        public Builder origin(String value) {
            this.origin = Field.ofNullable(value);
            return this;
        }
        public Builder pinned(Boolean value) {
            this.pinned = Field.ofNullable(value);
            return this;
        }
        public Builder title(String value) {
            this.title = Field.ofNullable(value);
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public SetWorkspaceMetadataRequest build() { return new SetWorkspaceMetadataRequest(this); }
    }
}
