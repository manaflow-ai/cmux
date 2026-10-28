// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class DaemonStartupMarks implements WireValue {
    /** Microseconds after main_start_unix_us (monotonic clock) at which this step was first reached; absent until reached. The startup configuration was read. */
    private final Field<UInt64> configLoaded;
    /** Microseconds after main_start_unix_us (monotonic clock) at which this step was first reached; absent until reached. The first identify answered once the lifecycle is ready, so it is the last step. */
    private final Field<UInt64> firstIdentifyServed;
    /** Microseconds after main_start_unix_us (monotonic clock) at which this step was first reached; absent until reached. The launch snapshot writer step is done. */
    private final Field<UInt64> launchSnapshotWriterStarted;
    /** Microseconds after main_start_unix_us (monotonic clock) at which this step was first reached; absent until reached. Every owner the lifecycle commands need is installed. */
    private final Field<UInt64> lifecycleReady;
    /** Unix microseconds (wall clock) when the daemon binary's main began: the origin of every step below. */
    private final UInt64 mainStartUnixUs;
    /** Microseconds after main_start_unix_us (monotonic clock) at which this step was first reached; absent until reached. The registry is open and its terminals adopted. */
    private final Field<UInt64> muxRestored;
    /** Microseconds after main_start_unix_us (monotonic clock) at which this step was first reached; absent until reached. The local owner's event loop runs. */
    private final Field<UInt64> ownerEventLoop;
    /** Microseconds after main_start_unix_us (monotonic clock) at which this step was first reached; absent until reached. The owner's process setup ran. */
    private final Field<UInt64> ownerPrepared;
    /** Microseconds after main_start_unix_us (monotonic clock) at which this step was first reached; absent until reached. The session socket is bound and answers as a restoring owner. */
    private final Field<UInt64> socketBound;
    /** Microseconds after main_start_unix_us (monotonic clock) at which this step was first reached; absent until reached. The WebSocket control listener step is done (bound, or none asked). */
    private final Field<UInt64> websocketReady;

    private DaemonStartupMarks(Builder builder) {
        this.configLoaded = builder.configLoaded;
        this.firstIdentifyServed = builder.firstIdentifyServed;
        this.launchSnapshotWriterStarted = builder.launchSnapshotWriterStarted;
        this.lifecycleReady = builder.lifecycleReady;
        if (!builder.mainStartUnixUsSet) throw new IllegalArgumentException("main_start_unix_us is required");
        this.mainStartUnixUs = Wire.nonNull(builder.mainStartUnixUs, "main_start_unix_us");
        this.muxRestored = builder.muxRestored;
        this.ownerEventLoop = builder.ownerEventLoop;
        this.ownerPrepared = builder.ownerPrepared;
        this.socketBound = builder.socketBound;
        this.websocketReady = builder.websocketReady;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> configLoaded() { return configLoaded; }
    public Field<UInt64> firstIdentifyServed() { return firstIdentifyServed; }
    public Field<UInt64> launchSnapshotWriterStarted() { return launchSnapshotWriterStarted; }
    public Field<UInt64> lifecycleReady() { return lifecycleReady; }
    public UInt64 mainStartUnixUs() { return mainStartUnixUs; }
    public Field<UInt64> muxRestored() { return muxRestored; }
    public Field<UInt64> ownerEventLoop() { return ownerEventLoop; }
    public Field<UInt64> ownerPrepared() { return ownerPrepared; }
    public Field<UInt64> socketBound() { return socketBound; }
    public Field<UInt64> websocketReady() { return websocketReady; }

    public static DaemonStartupMarks fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DaemonStartupMarks");
        Builder builder = builder();
        Object rawConfigLoaded = Wire.optional(object, "config_loaded");
        if (!Wire.isMissing(rawConfigLoaded)) {
            builder.configLoaded(Wire.uint64(rawConfigLoaded, "DaemonStartupMarks.config_loaded"));
        }
        Object rawFirstIdentifyServed = Wire.optional(object, "first_identify_served");
        if (!Wire.isMissing(rawFirstIdentifyServed)) {
            builder.firstIdentifyServed(Wire.uint64(rawFirstIdentifyServed, "DaemonStartupMarks.first_identify_served"));
        }
        Object rawLaunchSnapshotWriterStarted = Wire.optional(object, "launch_snapshot_writer_started");
        if (!Wire.isMissing(rawLaunchSnapshotWriterStarted)) {
            builder.launchSnapshotWriterStarted(Wire.uint64(rawLaunchSnapshotWriterStarted, "DaemonStartupMarks.launch_snapshot_writer_started"));
        }
        Object rawLifecycleReady = Wire.optional(object, "lifecycle_ready");
        if (!Wire.isMissing(rawLifecycleReady)) {
            builder.lifecycleReady(Wire.uint64(rawLifecycleReady, "DaemonStartupMarks.lifecycle_ready"));
        }
        Object rawMainStartUnixUs = Wire.required(object, "main_start_unix_us");
        builder.mainStartUnixUs(Wire.uint64(rawMainStartUnixUs, "DaemonStartupMarks.main_start_unix_us"));
        Object rawMuxRestored = Wire.optional(object, "mux_restored");
        if (!Wire.isMissing(rawMuxRestored)) {
            builder.muxRestored(Wire.uint64(rawMuxRestored, "DaemonStartupMarks.mux_restored"));
        }
        Object rawOwnerEventLoop = Wire.optional(object, "owner_event_loop");
        if (!Wire.isMissing(rawOwnerEventLoop)) {
            builder.ownerEventLoop(Wire.uint64(rawOwnerEventLoop, "DaemonStartupMarks.owner_event_loop"));
        }
        Object rawOwnerPrepared = Wire.optional(object, "owner_prepared");
        if (!Wire.isMissing(rawOwnerPrepared)) {
            builder.ownerPrepared(Wire.uint64(rawOwnerPrepared, "DaemonStartupMarks.owner_prepared"));
        }
        Object rawSocketBound = Wire.optional(object, "socket_bound");
        if (!Wire.isMissing(rawSocketBound)) {
            builder.socketBound(Wire.uint64(rawSocketBound, "DaemonStartupMarks.socket_bound"));
        }
        Object rawWebsocketReady = Wire.optional(object, "websocket_ready");
        if (!Wire.isMissing(rawWebsocketReady)) {
            builder.websocketReady(Wire.uint64(rawWebsocketReady, "DaemonStartupMarks.websocket_ready"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "config_loaded", configLoaded);
        Wire.put(object, "first_identify_served", firstIdentifyServed);
        Wire.put(object, "launch_snapshot_writer_started", launchSnapshotWriterStarted);
        Wire.put(object, "lifecycle_ready", lifecycleReady);
        Wire.put(object, "main_start_unix_us", mainStartUnixUs);
        Wire.put(object, "mux_restored", muxRestored);
        Wire.put(object, "owner_event_loop", ownerEventLoop);
        Wire.put(object, "owner_prepared", ownerPrepared);
        Wire.put(object, "socket_bound", socketBound);
        Wire.put(object, "websocket_ready", websocketReady);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DaemonStartupMarks that)) return false;
        return Objects.equals(configLoaded, that.configLoaded) && Objects.equals(firstIdentifyServed, that.firstIdentifyServed) && Objects.equals(launchSnapshotWriterStarted, that.launchSnapshotWriterStarted) && Objects.equals(lifecycleReady, that.lifecycleReady) && Objects.equals(mainStartUnixUs, that.mainStartUnixUs) && Objects.equals(muxRestored, that.muxRestored) && Objects.equals(ownerEventLoop, that.ownerEventLoop) && Objects.equals(ownerPrepared, that.ownerPrepared) && Objects.equals(socketBound, that.socketBound) && Objects.equals(websocketReady, that.websocketReady);
    }

    @Override
    public int hashCode() { return Objects.hash(configLoaded, firstIdentifyServed, launchSnapshotWriterStarted, lifecycleReady, mainStartUnixUs, muxRestored, ownerEventLoop, ownerPrepared, socketBound, websocketReady); }

    @Override
    public String toString() { return "DaemonStartupMarks" + toWire(); }

    public static final class Builder {
        private Field<UInt64> configLoaded = Field.omitted();
        private Field<UInt64> firstIdentifyServed = Field.omitted();
        private Field<UInt64> launchSnapshotWriterStarted = Field.omitted();
        private Field<UInt64> lifecycleReady = Field.omitted();
        private UInt64 mainStartUnixUs;
        private boolean mainStartUnixUsSet;
        private Field<UInt64> muxRestored = Field.omitted();
        private Field<UInt64> ownerEventLoop = Field.omitted();
        private Field<UInt64> ownerPrepared = Field.omitted();
        private Field<UInt64> socketBound = Field.omitted();
        private Field<UInt64> websocketReady = Field.omitted();

        public Builder configLoaded(UInt64 value) {
            this.configLoaded = Field.of(value);
            return this;
        }
        public Builder firstIdentifyServed(UInt64 value) {
            this.firstIdentifyServed = Field.of(value);
            return this;
        }
        public Builder launchSnapshotWriterStarted(UInt64 value) {
            this.launchSnapshotWriterStarted = Field.of(value);
            return this;
        }
        public Builder lifecycleReady(UInt64 value) {
            this.lifecycleReady = Field.of(value);
            return this;
        }
        public Builder mainStartUnixUs(UInt64 value) {
            this.mainStartUnixUs = value;
            this.mainStartUnixUsSet = true;
            return this;
        }
        public Builder muxRestored(UInt64 value) {
            this.muxRestored = Field.of(value);
            return this;
        }
        public Builder ownerEventLoop(UInt64 value) {
            this.ownerEventLoop = Field.of(value);
            return this;
        }
        public Builder ownerPrepared(UInt64 value) {
            this.ownerPrepared = Field.of(value);
            return this;
        }
        public Builder socketBound(UInt64 value) {
            this.socketBound = Field.of(value);
            return this;
        }
        public Builder websocketReady(UInt64 value) {
            this.websocketReady = Field.of(value);
            return this;
        }
        public DaemonStartupMarks build() { return new DaemonStartupMarks(this); }
    }
}
