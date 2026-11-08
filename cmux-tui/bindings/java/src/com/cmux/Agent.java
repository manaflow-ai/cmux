package com.cmux;

import java.util.Objects;

/** Immutable agent resource handle. */
public final class Agent {
    private final Client client;
    private final Route route;
    private final Snapshots.AgentSnapshot snapshot;

    Agent(Client client, Route route, Snapshots.AgentSnapshot snapshot) {
        this.client = Objects.requireNonNull(client, "client");
        this.route = Objects.requireNonNull(route, "route");
        this.snapshot = Objects.requireNonNull(snapshot, "snapshot");
    }

    public Snapshots.AgentSnapshot snapshot() {
        return snapshot;
    }

    Client client() {
        return client;
    }

    Route route() {
        return route;
    }
}
