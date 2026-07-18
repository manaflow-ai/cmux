package com.cmux;

import java.time.Duration;

public final class TopologySubscription implements TopologySubscribeOutcome, AutoCloseable {
    private final TopologySubscribed info;
    private final CmuxClient.CmuxStream stream;
    private TopologyCursor cursor;

    TopologySubscription(TopologySubscribed info, CmuxClient.CmuxStream stream, TopologyCursor cursor) {
        this.info = info;
        this.stream = stream;
        this.cursor = cursor;
    }

    public TopologySubscribed info() { return info; }
    public synchronized TopologyCursor cursor() { return cursor; }

    public synchronized TopologyStreamEvent next(Duration timeout) throws CmuxException {
        CmuxEvent event = stream.next(timeout);
        if (event instanceof TopologyResnapshotRequired required) {
            stream.close();
            return required;
        }
        if (!(event instanceof TopologyDelta delta)) {
            stream.close();
            throw new CmuxDecodeException("unexpected topology stream event " + event.event(), null);
        }
        TopologyResnapshotRequired required = validate(cursor, delta);
        if (required != null) {
            stream.close();
            return required;
        }
        cursor = new TopologyCursor(cursor.daemonInstanceId(), cursor.sessionId(), delta.revision());
        return delta;
    }

    static TopologyResnapshotRequired validate(TopologyCursor cursor, TopologyDelta delta) {
        TopologyResnapshotReason reason = null;
        if (!delta.daemonInstanceId().equals(cursor.daemonInstanceId())) {
            reason = TopologyResnapshotReason.STALE_DAEMON;
        } else if (!delta.sessionId().equals(cursor.sessionId())) {
            reason = TopologyResnapshotReason.STALE_SESSION;
        } else if (delta.baseRevision() != cursor.revision()
            || delta.baseRevision() == Long.MAX_VALUE
            || delta.revision() != delta.baseRevision() + 1) {
            reason = TopologyResnapshotReason.HISTORY_GAP;
        }
        return reason == null ? null : new TopologyResnapshotRequired(
            delta.daemonInstanceId(), delta.sessionId(), delta.revision(), reason
        );
    }

    @Override public void close() throws CmuxException { stream.close(); }
}
