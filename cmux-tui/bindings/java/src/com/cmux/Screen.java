package com.cmux;

import com.cmux.internal.Operations;
import com.cmux.internal.Wire;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

public final class Screen {
    private final Client client;
    private final Route route;
    private volatile Snapshots.ScreenSnapshot snapshot;

    Screen(Client client, Route route) {
        this(client, route, null);
    }

    Screen(Client client, Route route, Snapshots.ScreenSnapshot snapshot) {
        this.client = Objects.requireNonNull(client, "client");
        this.route = Objects.requireNonNull(route, "route");
        this.snapshot = snapshot;
    }

    public Optional<Snapshots.ScreenSnapshot> cached() {
        return Optional.ofNullable(snapshot);
    }

    public Snapshots.ScreenSnapshot refresh() {
        snapshot = Client.decodeScreen(Client.resourcePayload(
            client.request(Operations.SCREEN_GET, route.params(), null),
            Wire.SCREEN
        ));
        return snapshot;
    }

    public MutationResult<Snapshots.ScreenSnapshot> rename(
        Options.ScreenRename options
    ) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        params.put(Wire.NAME, options.name());
        return mutateSnapshot(Operations.SCREEN_RENAME, params, options.mutation());
    }

    public MutationResult<Snapshots.ScreenSnapshot> focus(Options.Mutation options) {
        return mutateSnapshot(
            Operations.SCREEN_FOCUS,
            withExtra(route.params(), options.extra()),
            options
        );
    }

    public MutationResult<EmptyResult> close(Options.Mutation options) {
        Client.MutationResponse response = client.mutation(
            Operations.SCREEN_CLOSE,
            withExtra(route.params(), options.extra()),
            options
        );
        return response.parts().withValue(
            Client.decodeEmptyMutation(response.result())
        );
    }

    public Layout.Document exportLayout(Options.Read options) {
        return Client.decodeLayoutDocument(client.requestValue(
            Operations.SCREEN_LAYOUT_EXPORT,
            withExtra(route.params(), options == null ? Map.of() : options.extra()),
            null
        ));
    }

    public MutationResult<Snapshots.ScreenSnapshot> undoLayout(
        Options.LayoutUndo options
    ) {
        Map<String, Object> params = withExtra(
            route.params(),
            options.mutation().extra()
        );
        if (options.confirmClose()) {
            params.put("confirm_close", true);
        }
        options.confirmationToken().ifPresent(
            token -> params.put("confirmation_token", token)
        );
        return mutateSnapshot(
            Operations.SCREEN_LAYOUT_UNDO,
            params,
            options.mutation()
        );
    }

    public Pane pane(Selector<Ids.PaneId> selector) {
        return new Pane(client, route.pane(selector));
    }

    public List<Pane> listPanes(Options.Read options) {
        Object result = client.requestValue(
            Operations.PANE_LIST,
            withExtra(route.params(), options == null ? Map.of() : options.extra()),
            null
        );
        List<Pane> panes = new ArrayList<>();
        for (Object value : Client.listPayload(result, "panes")) {
            Snapshots.PaneSnapshot decoded = Client.decodePane(value);
            panes.add(new Pane(client, route.pane(Selector.id(decoded.id())), decoded));
        }
        return List.copyOf(panes);
    }

    public List<Pane> findPanesByName(String name) {
        return listPanes(Options.Read.defaults()).stream()
            .filter(pane -> pane.cached().flatMap(Snapshots.PaneSnapshot::name)
                .map(name::equals).orElse(false))
            .toList();
    }

    public MutationResult<CreatedTerminalPath> createPane(
        Options.PaneCreate options
    ) {
        Map<String, Object> params = withExtra(route.params(), options.mutation().extra());
        options.cwd().ifPresent(value -> params.put(Wire.CWD, value));
        options.columns().ifPresent(value -> params.put(Wire.COLS, value));
        options.rows().ifPresent(value -> params.put(Wire.ROWS, value));
        options.correlationKey().ifPresent(
            key -> params.put("correlation_key", key)
        );
        Client.MutationResponse response = client.mutation(
            Operations.PANE_CREATE, params, options.mutation()
        );
        return response.parts().withValue(
            Client.decodeCreatedTerminalPath(response.result())
        );
    }

    private MutationResult<Snapshots.ScreenSnapshot> mutateSnapshot(
        Operations operation,
        Map<String, Object> params,
        Options.Mutation options
    ) {
        Client.MutationResponse response = client.mutation(operation, params, options);
        snapshot = Client.decodeScreen(
            Client.resourcePayload(response.result(), Wire.SCREEN)
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
