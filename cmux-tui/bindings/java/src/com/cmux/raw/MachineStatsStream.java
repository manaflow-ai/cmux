// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

/** Initial machine-stats response and its follow events. */
public final class MachineStatsStream implements AutoCloseable {
    private final MachineStatsResult initialResult;
    private final CmuxStream<ProtocolEvent> events;

    MachineStatsStream(MachineStatsResult initialResult, CmuxStream<ProtocolEvent> events) {
        this.initialResult = initialResult;
        this.events = events;
    }

    public MachineStatsResult initialResult() { return initialResult; }
    public ProtocolEvent next() throws CmuxException { return events.next(); }
    public void close() { events.close(); }
}
