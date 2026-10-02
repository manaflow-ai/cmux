package com.cmux;

import com.cmux.internal.Operations;
import com.cmux.internal.Wire;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

public final class Tab {
    private final Client client;
    private final Route route;
    private volatile Snapshots.TabSnapshot snapshot;

    Tab(Client client, Route route) {
        this(client, route, null);
    }

    Tab(Client client, Route route, Snapshots.TabSnapshot snapshot) {
        this.client = Objects.requireNonNull(client, "client");
        this.route = Objects.requireNonNull(route, "route");
        this.snapshot = snapshot;
    }

    public Optional<Snapshots.TabSnapshot> cached() {
        return Optional.ofNullable(snapshot);
    }

    public Snapshots.TabSnapshot refresh() {
        snapshot = Client.decodeTab(Client.resourcePayload(
            client.request(Operations.TAB_GET, route.params(), null),
            Wire.TAB
        ));
        return snapshot;
    }

    public MutationResult<Snapshots.TabSnapshot> rename(Options.TabRename options) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        params.put(Wire.NAME, options.name());
        return mutateSnapshot(Operations.TAB_RENAME, params, options.mutation());
    }

    public MutationResult<Snapshots.TabSnapshot> move(Options.TabMove options) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        params.put("destination_workspace", options.workspace());
        params.put("destination_screen", options.screen());
        params.put("destination_pane", options.pane());
        params.put("index", options.index());
        return mutateSnapshot(Operations.TAB_MOVE, params, options.mutation());
    }

    public MutationResult<Snapshots.TabSnapshot> focus(Options.Mutation options) {
        return mutateSnapshot(
            Operations.TAB_FOCUS,
            withExtra(route.params(), options.extra()),
            options
        );
    }

    public MutationResult<EmptyResult> close(Options.Mutation options) {
        Client.MutationResponse response = client.mutation(
            Operations.TAB_CLOSE,
            withExtra(route.params(), options.extra()),
            options
        );
        return response.parts().withValue(
            Client.decodeEmptyMutation(response.result())
        );
    }

    public Terminal terminal(Selector<Ids.TerminalId> selector) {
        return new Terminal(client, route, selector);
    }

    public Browser browser(Selector<Ids.BrowserId> selector) {
        return new Browser(client, route, selector);
    }

    private MutationResult<Snapshots.TabSnapshot> mutateSnapshot(
        Operations operation,
        Map<String, Object> params,
        Options.Mutation options
    ) {
        Client.MutationResponse response = client.mutation(operation, params, options);
        snapshot = Client.decodeTab(
            Client.resourcePayload(response.result(), Wire.TAB)
        );
        return response.parts().withValue(snapshot);
    }

    private static Map<String, Object> withExtra(
        Map<String, Object> params,
        Map<String, Object> extra
    ) {
        params.putAll(extra);
        return params;
    }
}
