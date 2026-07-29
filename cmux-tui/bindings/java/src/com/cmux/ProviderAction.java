package com.cmux;

import com.cmux.internal.Operations;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** An invokable provider action. */
public final class ProviderAction {
    private final Client client;
    private final Map<String, Object> selectors;
    private final Snapshots.ProviderActionSnapshot snapshot;

    ProviderAction(
        Client client,
        Map<String, Object> selectors,
        Snapshots.ProviderActionSnapshot snapshot
    ) {
        this.client = Objects.requireNonNull(client, "client");
        this.selectors = Map.copyOf(selectors);
        this.snapshot = snapshot;
    }

    public Optional<Snapshots.ProviderActionSnapshot> cached() {
        return Optional.ofNullable(snapshot);
    }

    public MutationResult<JsonValue> invoke(Options.ProviderInvoke options) {
        Map<String, Object> params = Client.copy(selectors);
        params.putAll(options.mutation().extra());
        params.put("parameters", options.parameters());
        Client.MutationResponse response = client.mutation(
            Operations.PROVIDER_ACTION_INVOKE, params, options.mutation()
        );
        if (!response.result().containsKey("value")) {
            throw new ProtocolError("provider action result omitted value");
        }
        return response.parts().withValue(
            JsonValue.of(response.result().get("value"))
        );
    }
}
