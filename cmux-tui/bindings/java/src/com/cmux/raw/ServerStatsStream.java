// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

/** Initial server-stats response and its follow events. */
public final class ServerStatsStream implements AutoCloseable {
    private final ServerStatsResult initialResult;
    private final CmuxStream<ProtocolEvent> events;

    ServerStatsStream(ServerStatsResult initialResult, CmuxStream<ProtocolEvent> events) {
        this.initialResult = initialResult;
        this.events = events;
    }

    public ServerStatsResult initialResult() { return initialResult; }
    public ProtocolEvent next() throws CmuxException { return events.next(); }
    public void close() { events.close(); }
}
