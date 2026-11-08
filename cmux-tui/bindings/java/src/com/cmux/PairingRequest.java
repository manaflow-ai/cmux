package com.cmux;

import com.cmux.internal.Operations;
import com.cmux.internal.Wire;
import java.util.Map;
import java.util.Objects;

/** A pending or resolved pairing request. */
public final class PairingRequest {
    private final Client client;
    private final Route route;
    private volatile Snapshots.PairingRequestSnapshot snapshot;

    PairingRequest(
        Client client,
        Route route,
        Snapshots.PairingRequestSnapshot snapshot
    ) {
        this.client = Objects.requireNonNull(client, "client");
        this.route = Objects.requireNonNull(route, "route");
        this.snapshot = Objects.requireNonNull(snapshot, "snapshot");
    }

    public Snapshots.PairingRequestSnapshot snapshot() {
        return snapshot;
    }

    public MutationResult<Results.PairingResolutionResult> resolve(
        Options.PairingResolve options
    ) {
        Map<String, Object> params = route.target(
            "pairing_request",
            Selector.id(snapshot.id())
        );
        params.putAll(options.mutation().extra());
        params.put("decision", options.decision().toWire());
        Client.MutationResponse response = client.mutation(
            Operations.PAIRING_REQUEST_RESOLVE, params, options.mutation()
        );
        Results.PairingResolutionResult result = Client.decodePairingResolution(
            response.result().get(Wire.VALUE)
        );
        snapshot = result.pairingRequest();
        return response.parts().withValue(result);
    }
}
