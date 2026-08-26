package com.cmux;

import java.util.Objects;

/** Immutable notification resource handle. */
public final class Notification {
    private final Client client;
    private final Route route;
    private final Snapshots.NotificationSnapshot snapshot;

    Notification(
        Client client,
        Route route,
        Snapshots.NotificationSnapshot snapshot
    ) {
        this.client = Objects.requireNonNull(client, "client");
        this.route = Objects.requireNonNull(route, "route");
        this.snapshot = Objects.requireNonNull(snapshot, "snapshot");
    }

    public Snapshots.NotificationSnapshot snapshot() {
        return snapshot;
    }

    Client client() {
        return client;
    }

    Route route() {
        return route;
    }
}
