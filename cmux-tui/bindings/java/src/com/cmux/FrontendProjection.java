package com.cmux;

import com.cmux.internal.Operations;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** A frontend projection resource. */
public final class FrontendProjection {
    private final Client client;
    private final Route route;
    private final Selector<Ids.ProjectionId> selector;
    private volatile Snapshots.FrontendProjectionSnapshot snapshot;

    FrontendProjection(
        Client client,
        Route route,
        Selector<Ids.ProjectionId> selector
    ) {
        this.client = Objects.requireNonNull(client, "client");
        this.route = Objects.requireNonNull(route, "route");
        this.selector = Objects.requireNonNull(selector, "selector");
    }

    public Optional<Snapshots.FrontendProjectionSnapshot> cached() {
        return Optional.ofNullable(snapshot);
    }

    public Snapshots.FrontendProjectionSnapshot refresh() {
        snapshot = Client.decodeFrontendProjection(Client.resourcePayload(
            client.request(Operations.FRONTEND_PROJECTION_GET, params(), null),
            "frontend_projection"
        ));
        return snapshot;
    }

    public MutationResult<Snapshots.FrontendProjectionSnapshot> put(
        Options.ProjectionPut options
    ) {
        Map<String, Object> params = params();
        params.putAll(options.mutation().extra());
        params.put("frontend_id", options.frontendId());
        params.put("window_id", options.windowId());
        params.put("generation", options.generation());
        params.put("projection", options.projection());
        options.expectedProjectionRevision().ifPresent(value ->
            params.put("expected_projection_revision", value)
        );
        Client.MutationResponse response = client.mutation(
            Operations.FRONTEND_PROJECTION_PUT, params, options.mutation()
        );
        snapshot = Client.decodeFrontendProjection(Client.resourcePayload(
            response.result(), "frontend_projection"
        ));
        return response.parts().withValue(snapshot);
    }

    private Map<String, Object> params() {
        return route.target("frontend_projection", selector);
    }
}
