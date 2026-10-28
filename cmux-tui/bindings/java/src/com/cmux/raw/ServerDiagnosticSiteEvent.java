// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable server-diagnostic-site event. Protocol v12; streams: subscribe. */
public final class ServerDiagnosticSiteEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    /** Blocking and inversion: the crate of the call site without its version, or other. Never a path. */
    private final Field<String> crate;
    /** blocking: a blocking call where blocking is disallowed (or a work item's wait for other work); inversion: a wait on work of lower QoS; hang: a request method that ran past the 250 ms watchdog threshold, or a holder-link frame or a journal commit past its hang tier. */
    private final ServerDiagnosticSiteEventFamily family;
    /** Blocking and inversion: 16 hex digits, FNV-1a of the file's path from the crate folder on. Never a path. */
    private final Field<String> fileHash;
    /** The blocking kind (cmux_threads BlockingKind names: fs, sleep, recv, priority-inversion, ...), or for a hang its scope: request, holder-link or journal-writer. */
    private final String kind;
    /** Blocking: a work item's wait for other work. */
    private final Field<Boolean> laneSync;
    /** Blocking and inversion: the call site's line. */
    private final Field<Long> line;
    /** Hang: what ran: the request's command or v2 operation name (a colon written as a dot), the holder frame kind (data, exit, ...) or commit-batch. */
    private final Field<String> method;

    private ServerDiagnosticSiteEvent(Builder builder) {
        this.cause = builder.cause;
        this.crate = builder.crate;
        if (!builder.familySet) throw new IllegalArgumentException("family is required");
        this.family = Wire.nonNull(builder.family, "family");
        this.fileHash = builder.fileHash;
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        this.laneSync = builder.laneSync;
        this.line = builder.line;
        this.method = builder.method;
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public Field<String> crate() { return crate; }
    public ServerDiagnosticSiteEventFamily family() { return family; }
    public Field<String> fileHash() { return fileHash; }
    public String kind() { return kind; }
    public Field<Boolean> laneSync() { return laneSync; }
    public Field<Long> line() { return line; }
    public Field<String> method() { return method; }
    @Override public String event() { return "server-diagnostic-site"; }

    public static ServerDiagnosticSiteEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerDiagnosticSiteEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "server-diagnostic-site", "ServerDiagnosticSiteEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawCrate = Wire.optional(object, "crate");
        if (!Wire.isMissing(rawCrate)) {
            builder.crate(Wire.string(rawCrate, "ServerDiagnosticSiteEvent.crate"));
        }
        Object rawFamily = Wire.required(object, "family");
        builder.family(ServerDiagnosticSiteEventFamily.fromWire(rawFamily));
        Object rawFileHash = Wire.optional(object, "file_hash");
        if (!Wire.isMissing(rawFileHash)) {
            builder.fileHash(Wire.string(rawFileHash, "ServerDiagnosticSiteEvent.file_hash"));
        }
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "ServerDiagnosticSiteEvent.kind"));
        Object rawLaneSync = Wire.optional(object, "lane_sync");
        if (!Wire.isMissing(rawLaneSync)) {
            builder.laneSync(Wire.bool(rawLaneSync, "ServerDiagnosticSiteEvent.lane_sync"));
        }
        Object rawLine = Wire.optional(object, "line");
        if (!Wire.isMissing(rawLine)) {
            builder.line(Wire.uint32(rawLine, "ServerDiagnosticSiteEvent.line"));
        }
        Object rawMethod = Wire.optional(object, "method");
        if (!Wire.isMissing(rawMethod)) {
            builder.method(Wire.string(rawMethod, "ServerDiagnosticSiteEvent.method"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "server-diagnostic-site");
        Wire.put(object, "cause", cause);
        Wire.put(object, "crate", crate);
        Wire.put(object, "family", family);
        Wire.put(object, "file_hash", fileHash);
        Wire.put(object, "kind", kind);
        Wire.put(object, "lane_sync", laneSync);
        Wire.put(object, "line", line);
        Wire.put(object, "method", method);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerDiagnosticSiteEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(crate, that.crate) && Objects.equals(family, that.family) && Objects.equals(fileHash, that.fileHash) && Objects.equals(kind, that.kind) && Objects.equals(laneSync, that.laneSync) && Objects.equals(line, that.line) && Objects.equals(method, that.method);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, crate, family, fileHash, kind, laneSync, line, method); }

    @Override
    public String toString() { return "ServerDiagnosticSiteEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private Field<String> crate = Field.omitted();
        private ServerDiagnosticSiteEventFamily family;
        private boolean familySet;
        private Field<String> fileHash = Field.omitted();
        private String kind;
        private boolean kindSet;
        private Field<Boolean> laneSync = Field.omitted();
        private Field<Long> line = Field.omitted();
        private Field<String> method = Field.omitted();

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder crate(String value) {
            this.crate = Field.of(value);
            return this;
        }
        public Builder family(ServerDiagnosticSiteEventFamily value) {
            this.family = value;
            this.familySet = true;
            return this;
        }
        public Builder fileHash(String value) {
            this.fileHash = Field.of(value);
            return this;
        }
        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder laneSync(Boolean value) {
            this.laneSync = Field.of(value);
            return this;
        }
        public Builder line(Long value) {
            this.line = Field.of(value);
            return this;
        }
        public Builder method(String value) {
            this.method = Field.of(value);
            return this;
        }
        public ServerDiagnosticSiteEvent build() { return new ServerDiagnosticSiteEvent(this); }
    }
}
