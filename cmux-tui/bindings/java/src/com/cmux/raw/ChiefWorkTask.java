// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ChiefWorkTask implements WireValue {
    private final String command;
    private final String detail;
    private final UInt64 endedAt;
    private final String id;
    private final String sessionId;
    private final UInt64 startedAt;
    private final ChiefWorkTaskStatus status;
    private final String title;

    private ChiefWorkTask(Builder builder) {
        if (!builder.commandSet) throw new IllegalArgumentException("command is required");
        this.command = Wire.nonNull(builder.command, "command");
        if (!builder.detailSet) throw new IllegalArgumentException("detail is required");
        this.detail = builder.detail;
        if (!builder.endedAtSet) throw new IllegalArgumentException("endedAt is required");
        this.endedAt = builder.endedAt;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.sessionIdSet) throw new IllegalArgumentException("sessionId is required");
        this.sessionId = Wire.nonNull(builder.sessionId, "sessionId");
        if (!builder.startedAtSet) throw new IllegalArgumentException("startedAt is required");
        this.startedAt = builder.startedAt;
        if (!builder.statusSet) throw new IllegalArgumentException("status is required");
        this.status = Wire.nonNull(builder.status, "status");
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
    }

    public static Builder builder() { return new Builder(); }

    public String command() { return command; }
    public String detail() { return detail; }
    public UInt64 endedAt() { return endedAt; }
    public String id() { return id; }
    public String sessionId() { return sessionId; }
    public UInt64 startedAt() { return startedAt; }
    public ChiefWorkTaskStatus status() { return status; }
    public String title() { return title; }

    public static ChiefWorkTask fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ChiefWorkTask");
        Builder builder = builder();
        Object rawCommand = Wire.required(object, "command");
        builder.command(Wire.string(rawCommand, "ChiefWorkTask.command"));
        Object rawDetail = Wire.required(object, "detail");
        builder.detail(rawDetail == null ? null : Wire.string(rawDetail, "ChiefWorkTask.detail"));
        Object rawEndedAt = Wire.required(object, "endedAt");
        builder.endedAt(rawEndedAt == null ? null : Wire.uint64(rawEndedAt, "ChiefWorkTask.endedAt"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "ChiefWorkTask.id"));
        Object rawSessionId = Wire.required(object, "sessionId");
        builder.sessionId(Wire.string(rawSessionId, "ChiefWorkTask.sessionId"));
        Object rawStartedAt = Wire.required(object, "startedAt");
        builder.startedAt(rawStartedAt == null ? null : Wire.uint64(rawStartedAt, "ChiefWorkTask.startedAt"));
        Object rawStatus = Wire.required(object, "status");
        builder.status(ChiefWorkTaskStatus.fromWire(rawStatus));
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "ChiefWorkTask.title"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "command", command);
        Wire.put(object, "detail", detail);
        Wire.put(object, "endedAt", endedAt);
        Wire.put(object, "id", id);
        Wire.put(object, "sessionId", sessionId);
        Wire.put(object, "startedAt", startedAt);
        Wire.put(object, "status", status);
        Wire.put(object, "title", title);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ChiefWorkTask that)) return false;
        return Objects.equals(command, that.command) && Objects.equals(detail, that.detail) && Objects.equals(endedAt, that.endedAt) && Objects.equals(id, that.id) && Objects.equals(sessionId, that.sessionId) && Objects.equals(startedAt, that.startedAt) && Objects.equals(status, that.status) && Objects.equals(title, that.title);
    }

    @Override
    public int hashCode() { return Objects.hash(command, detail, endedAt, id, sessionId, startedAt, status, title); }

    @Override
    public String toString() { return "ChiefWorkTask" + toWire(); }

    public static final class Builder {
        private String command;
        private boolean commandSet;
        private String detail;
        private boolean detailSet;
        private UInt64 endedAt;
        private boolean endedAtSet;
        private String id;
        private boolean idSet;
        private String sessionId;
        private boolean sessionIdSet;
        private UInt64 startedAt;
        private boolean startedAtSet;
        private ChiefWorkTaskStatus status;
        private boolean statusSet;
        private String title;
        private boolean titleSet;

        public Builder command(String value) {
            this.command = value;
            this.commandSet = true;
            return this;
        }
        public Builder detail(String value) {
            this.detail = value;
            this.detailSet = true;
            return this;
        }
        public Builder endedAt(UInt64 value) {
            this.endedAt = value;
            this.endedAtSet = true;
            return this;
        }
        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder sessionId(String value) {
            this.sessionId = value;
            this.sessionIdSet = true;
            return this;
        }
        public Builder startedAt(UInt64 value) {
            this.startedAt = value;
            this.startedAtSet = true;
            return this;
        }
        public Builder status(ChiefWorkTaskStatus value) {
            this.status = value;
            this.statusSet = true;
            return this;
        }
        public Builder title(String value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public ChiefWorkTask build() { return new ChiefWorkTask(this); }
    }
}
